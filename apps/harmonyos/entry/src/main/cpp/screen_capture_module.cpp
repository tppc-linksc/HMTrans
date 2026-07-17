#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <hilog/log.h>
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <native_window/external_window.h>

namespace {

constexpr uint32_t CAST_LOG_DOMAIN = 0x3200;
constexpr const char *CAST_LOG_TAG = "HMTransCast";

struct FrameEvent {
    std::vector<uint8_t> bytes;
    int64_t ptsUs {0};
    uint32_t flags {0};
};

struct StateEvent {
    int32_t state {0};
    std::string message;
};

std::mutex gCaptureMutex;
OH_AVScreenCapture *gCapture = nullptr;
OH_AVCodec *gEncoder = nullptr;
OHNativeWindow *gEncoderSurface = nullptr;
bool gEncoderStarted = false;
std::atomic_bool gCapturing {false};
std::atomic<int64_t> gCaptureClockOriginUs {0};
std::atomic<int64_t> gLastPublishedPtsUs {-1};
std::atomic<uint64_t> gPublishedFrameCount {0};
napi_threadsafe_function gFrameCallback = nullptr;
napi_threadsafe_function gStateCallback = nullptr;

int64_t SteadyClockNowUs()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

int64_t NextPresentationTimeUs()
{
    int64_t origin = gCaptureClockOriginUs.load();
    if (origin <= 0) {
        origin = SteadyClockNowUs();
        gCaptureClockOriginUs.store(origin);
    }
    int64_t candidate = std::max<int64_t>(0, SteadyClockNowUs() - origin);
    int64_t previous = gLastPublishedPtsUs.load();
    while (candidate <= previous) {
        candidate = previous + 1;
        if (gLastPublishedPtsUs.compare_exchange_weak(previous, candidate)) {
            return candidate;
        }
    }
    while (!gLastPublishedPtsUs.compare_exchange_weak(previous, candidate)) {
        if (candidate <= previous) {
            candidate = previous + 1;
        }
    }
    return candidate;
}

void CallFrameJs(napi_env env, napi_value callback, void *, void *rawData)
{
    std::unique_ptr<FrameEvent> event(static_cast<FrameEvent *>(rawData));
    if (env == nullptr || callback == nullptr || event == nullptr) {
        return;
    }

    napi_value object;
    napi_create_object(env, &object);

    void *destination = nullptr;
    napi_value arrayBuffer;
    napi_create_arraybuffer(env, event->bytes.size(), &destination, &arrayBuffer);
    if (!event->bytes.empty() && destination != nullptr) {
        std::memcpy(destination, event->bytes.data(), event->bytes.size());
    }

    napi_value pts;
    napi_create_int64(env, event->ptsUs, &pts);
    napi_value flags;
    napi_create_uint32(env, event->flags, &flags);
    napi_set_named_property(env, object, "data", arrayBuffer);
    napi_set_named_property(env, object, "ptsUs", pts);
    napi_set_named_property(env, object, "flags", flags);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, callback, 1, &object, nullptr);
}

void CallStateJs(napi_env env, napi_value callback, void *, void *rawData)
{
    std::unique_ptr<StateEvent> event(static_cast<StateEvent *>(rawData));
    if (env == nullptr || callback == nullptr || event == nullptr) {
        return;
    }
    napi_value argv[2];
    napi_create_int32(env, event->state, &argv[0]);
    napi_create_string_utf8(env, event->message.c_str(), NAPI_AUTO_LENGTH, &argv[1]);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, callback, 2, argv, nullptr);
}

void PublishState(int32_t state, const std::string &message)
{
    if (gStateCallback == nullptr) {
        return;
    }
    auto *event = new StateEvent {state, message};
    if (napi_call_threadsafe_function(gStateCallback, event, napi_tsfn_nonblocking) != napi_ok) {
        delete event;
    }
}

void OnCaptureState(OH_AVScreenCapture *, OH_AVScreenCaptureStateCode state, void *)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, CAST_LOG_DOMAIN, CAST_LOG_TAG,
        "capture state changed: %{public}d", static_cast<int32_t>(state));
    switch (state) {
    case OH_SCREEN_CAPTURE_STATE_CANCELED:
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
    case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
        gCapturing.store(false);
        // 使用独立的负值区间表示系统主动终止，避免与系统原始状态码混淆。
        PublishState(-1000 - static_cast<int32_t>(state), "screen_capture_ended_by_system");
        return;
    default:
        // 麦克风和隐私场景的状态变化不会终止无声视频采集。
        PublishState(static_cast<int32_t>(state), "screen_capture_state_changed");
        return;
    }
}

void OnCaptureError(OH_AVScreenCapture *, int32_t errorCode, void *)
{
    OH_LOG_Print(LOG_APP, LOG_ERROR, CAST_LOG_DOMAIN, CAST_LOG_TAG,
        "screen capture error: %{public}d", errorCode);
    gCapturing.store(false);
    PublishState(errorCode == 0 ? -1 : -std::abs(errorCode), "screen_capture_error");
}

void OnEncoderError(OH_AVCodec *, int32_t errorCode, void *)
{
    OH_LOG_Print(LOG_APP, LOG_ERROR, CAST_LOG_DOMAIN, CAST_LOG_TAG,
        "video encoder error: %{public}d", errorCode);
    gCapturing.store(false);
    PublishState(errorCode == 0 ? -1 : -std::abs(errorCode), "video_encoder_error");
}

void OnEncoderFormatChanged(OH_AVCodec *, OH_AVFormat *, void *)
{
    OH_LOG_PrintMsg(LOG_APP, LOG_INFO, CAST_LOG_DOMAIN, CAST_LOG_TAG, "video encoder format changed");
}

void OnEncoderNeedsInput(OH_AVCodec *, uint32_t, OH_AVBuffer *, void *)
{
    // Surface 输入模式由 AVScreenCapture 直接向编码器 Surface 写入，不使用输入 Buffer 回调。
}

void OnEncoderOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *)
{
    if (buffer == nullptr) {
        return;
    }

    OH_AVCodecBufferAttr attr {};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        return;
    }

    if (gCapturing.load() && gFrameCallback != nullptr && attr.size > 0 && attr.offset >= 0) {
        uint8_t *address = OH_AVBuffer_GetAddr(buffer);
        int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
        if (address != nullptr && capacity > 0 && attr.offset <= capacity && attr.size <= capacity - attr.offset) {
            auto *event = new FrameEvent;
            event->bytes.assign(address + attr.offset, address + attr.offset + attr.size);
            // Surface 编码在部分真机上会返回纳秒单调时钟，尽管 SDK 字段说明为微秒。
            // 协议统一发送“本次投屏开始后的单调微秒”，避免把设备绝对时钟泄漏给接收端。
            event->ptsUs = NextPresentationTimeUs();
            event->flags = attr.flags;
            uint64_t frameNumber = gPublishedFrameCount.fetch_add(1) + 1;
            if (frameNumber <= 3 || frameNumber % 300 == 0) {
                OH_LOG_Print(LOG_APP, LOG_INFO, CAST_LOG_DOMAIN, CAST_LOG_TAG,
                    "encoded frame=%{public}llu size=%{public}d rawPts=%{public}lld sessionPtsUs=%{public}lld flags=%{public}u",
                    static_cast<unsigned long long>(frameNumber), attr.size,
                    static_cast<long long>(attr.pts), static_cast<long long>(event->ptsUs), attr.flags);
            }
            // 线程安全函数的队列上限为四帧；网络侧跟不上时丢帧而不阻塞编码器。
            if (napi_call_threadsafe_function(gFrameCallback, event, napi_tsfn_nonblocking) != napi_ok) {
                delete event;
            }
        }
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

void ReleaseCaptureLocked()
{
    gCapturing.store(false);
    gCaptureClockOriginUs.store(0);
    gLastPublishedPtsUs.store(-1);
    gPublishedFrameCount.store(0);
    if (gCapture != nullptr) {
        OH_AVScreenCapture_StopScreenCapture(gCapture);
        OH_AVScreenCapture_Release(gCapture);
        gCapture = nullptr;
    }
    if (gEncoder != nullptr) {
        if (gEncoderStarted) {
            OH_VideoEncoder_Stop(gEncoder);
        }
        gEncoderStarted = false;
        if (gEncoderSurface != nullptr) {
            OH_NativeWindow_DestroyNativeWindow(gEncoderSurface);
            gEncoderSurface = nullptr;
        }
        OH_VideoEncoder_Destroy(gEncoder);
        gEncoder = nullptr;
    }
}

void CleanupEnvironment(void *)
{
    {
        std::lock_guard<std::mutex> lock(gCaptureMutex);
        ReleaseCaptureLocked();
    }
    // Ark 运行环境退出时主动释放线程安全回调，防止热重载或页面销毁后残留原生资源。
    if (gFrameCallback != nullptr) {
        napi_release_threadsafe_function(gFrameCallback, napi_tsfn_abort);
        gFrameCallback = nullptr;
    }
    if (gStateCallback != nullptr) {
        napi_release_threadsafe_function(gStateCallback, napi_tsfn_abort);
        gStateCallback = nullptr;
    }
}

bool ReadInt32(napi_env env, napi_value object, const char *name, int32_t &value)
{
    napi_value property;
    if (napi_get_named_property(env, object, name, &property) != napi_ok) {
        return false;
    }
    return napi_get_value_int32(env, property, &value) == napi_ok;
}

napi_value RegisterCallback(napi_env env, napi_callback_info info, bool frameCallback)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc != 1 || napi_typeof(env, argv[0], &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, nullptr, "callback 必须是函数");
        return nullptr;
    }

    napi_threadsafe_function &slot = frameCallback ? gFrameCallback : gStateCallback;
    if (slot != nullptr) {
        napi_release_threadsafe_function(slot, napi_tsfn_abort);
        slot = nullptr;
    }
    napi_value resourceName;
    napi_create_string_utf8(env, frameCallback ? "HMTransCastFrame" : "HMTransCastState",
        NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_threadsafe_function(env, argv[0], nullptr, resourceName,
        frameCallback ? 4 : 8, 1, nullptr, nullptr, nullptr,
        frameCallback ? CallFrameJs : CallStateJs, &slot);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "无法注册原生投屏回调");
        return nullptr;
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value OnFrame(napi_env env, napi_callback_info info)
{
    return RegisterCallback(env, info, true);
}

napi_value OnState(napi_env env, napi_callback_info info)
{
    return RegisterCallback(env, info, false);
}

napi_value CreateStartResult(napi_env env, bool started, const char *stage, int32_t errorCode)
{
    napi_value result;
    napi_create_object(env, &result);
    napi_value startedValue;
    napi_get_boolean(env, started, &startedValue);
    napi_value stageValue;
    napi_create_string_utf8(env, stage, NAPI_AUTO_LENGTH, &stageValue);
    napi_value errorValue;
    napi_create_int32(env, errorCode, &errorValue);
    napi_set_named_property(env, result, "started", startedValue);
    napi_set_named_property(env, result, "stage", stageValue);
    napi_set_named_property(env, result, "errorCode", errorValue);
    return result;
}

napi_value StartCapture(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t width = 1920;
    int32_t height = 1200;
    int32_t frameRate = 30;
    int32_t bitrate = 8 * 1024 * 1024;
    if (argc != 1 || !ReadInt32(env, argv[0], "width", width) ||
        !ReadInt32(env, argv[0], "height", height) ||
        !ReadInt32(env, argv[0], "frameRate", frameRate) ||
        !ReadInt32(env, argv[0], "bitrate", bitrate)) {
        napi_throw_type_error(env, nullptr, "投屏采集参数不完整");
        return nullptr;
    }

    width = std::max(640, std::min(width, 3840));
    height = std::max(360, std::min(height, 2160));
    frameRate = std::max(15, std::min(frameRate, 60));
    bitrate = std::max(1024 * 1024, std::min(bitrate, 24 * 1024 * 1024));

    std::lock_guard<std::mutex> lock(gCaptureMutex);
    ReleaseCaptureLocked();
    gCaptureClockOriginUs.store(SteadyClockNowUs());
    gLastPublishedPtsUs.store(-1);
    gPublishedFrameCount.store(0);
    gCapture = OH_AVScreenCapture_Create();
    if (gCapture == nullptr) {
        return CreateStartResult(env, false, "create", AV_SCREEN_CAPTURE_ERR_NO_MEMORY);
    }

    // Phone/Tablet 从 API 23 起必须显式启用系统 Picker，才能让普通应用获得本次
    // 屏幕共享授权。CAPTURE_SCREEN 是 system_core 权限，不能用运行时权限代替 Picker。
    OH_AVScreenCapture_CaptureStrategy *strategy = OH_AVScreenCapture_CreateCaptureStrategy();
    if (strategy == nullptr) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "createPickerStrategy", AV_SCREEN_CAPTURE_ERR_NO_MEMORY);
    }
    OH_AVSCREEN_CAPTURE_ErrCode pickerResult = OH_AVScreenCapture_StrategyForPickerPopUp(strategy, true);
    OH_AVSCREEN_CAPTURE_ErrCode strategyResult = pickerResult == AV_SCREEN_CAPTURE_ERR_OK
        ? OH_AVScreenCapture_SetCaptureStrategy(gCapture, strategy)
        : pickerResult;
    OH_AVScreenCapture_ReleaseCaptureStrategy(strategy);
    if (strategyResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configurePicker", static_cast<int32_t>(strategyResult));
    }

    // AVScreenCapture 只负责生成原始 RGBA 画面。OH_ENCODED_STREAM 和
    // OH_VIDEO_SOURCE_SURFACE_ES 在 Phone/Tablet 普通应用场景不可直接使用，
    // H.264 必须由 AVCodec Surface 编码器产生。
    gEncoder = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (gEncoder == nullptr) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "createEncoder", AV_ERR_UNSUPPORT);
    }
    OH_AVCodecCallback encoderCallback {};
    encoderCallback.onError = OnEncoderError;
    encoderCallback.onStreamChanged = OnEncoderFormatChanged;
    encoderCallback.onNeedInputBuffer = OnEncoderNeedsInput;
    encoderCallback.onNewOutputBuffer = OnEncoderOutput;
    OH_AVErrCode encoderCallbackResult = OH_VideoEncoder_RegisterCallback(gEncoder, encoderCallback, nullptr);
    if (encoderCallbackResult != AV_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configureEncoderCallbacks",
            static_cast<int32_t>(encoderCallbackResult));
    }

    OH_AVFormat *encoderFormat = OH_AVFormat_CreateVideoFormat(OH_AVCODEC_MIMETYPE_VIDEO_AVC, width, height);
    if (encoderFormat == nullptr) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "createEncoderFormat", AV_ERR_NO_MEMORY);
    }
    bool encoderFormatReady =
        OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12) &&
        OH_AVFormat_SetDoubleValue(encoderFormat, OH_MD_KEY_FRAME_RATE, static_cast<double>(frameRate)) &&
        OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, CBR) &&
        OH_AVFormat_SetLongValue(encoderFormat, OH_MD_KEY_BITRATE, static_cast<int64_t>(bitrate)) &&
        // 实时投屏不需要 B 帧。Baseline + 显式禁用 B 帧保证编码顺序就是显示顺序，
        // Mac 不再需要猜测 DTS，也减少首帧后预测帧无法继续解码的风险。
        OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_PROFILE, AVC_PROFILE_BASELINE) &&
        OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_VIDEO_ENCODER_ENABLE_B_FRAME, 0) &&
        OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
    OH_AVErrCode encoderConfigureResult = encoderFormatReady
        ? OH_VideoEncoder_Configure(gEncoder, encoderFormat)
        : AV_ERR_INVALID_VAL;
    OH_AVFormat_Destroy(encoderFormat);
    if (encoderConfigureResult != AV_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configureEncoder", static_cast<int32_t>(encoderConfigureResult));
    }

    OH_AVErrCode encoderSurfaceResult = OH_VideoEncoder_GetSurface(gEncoder, &gEncoderSurface);
    if (encoderSurfaceResult != AV_ERR_OK || gEncoderSurface == nullptr) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "createEncoderSurface",
            encoderSurfaceResult == AV_ERR_OK ? AV_ERR_UNKNOWN : static_cast<int32_t>(encoderSurfaceResult));
    }
    OH_AVErrCode encoderPrepareResult = OH_VideoEncoder_Prepare(gEncoder);
    if (encoderPrepareResult != AV_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "prepareEncoder", static_cast<int32_t>(encoderPrepareResult));
    }

    OH_AVScreenCaptureConfig config {};
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;
    config.audioInfo.micCapInfo.audioSource = OH_SOURCE_INVALID;
    config.audioInfo.innerCapInfo.audioSource = OH_SOURCE_INVALID;
    config.videoInfo.videoCapInfo.videoFrameWidth = width;
    config.videoInfo.videoCapInfo.videoFrameHeight = height;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    config.videoInfo.videoEncInfo.videoCodec = OH_H264;
    config.videoInfo.videoEncInfo.videoBitrate = bitrate;
    config.videoInfo.videoEncInfo.videoFrameRate = frameRate;

    OH_AVSCREEN_CAPTURE_ErrCode stateCallbackResult =
        OH_AVScreenCapture_SetStateCallback(gCapture, OnCaptureState, nullptr);
    OH_AVSCREEN_CAPTURE_ErrCode errorCallbackResult =
        OH_AVScreenCapture_SetErrorCallback(gCapture, OnCaptureError, nullptr);
    if (stateCallbackResult != AV_SCREEN_CAPTURE_ERR_OK || errorCallbackResult != AV_SCREEN_CAPTURE_ERR_OK) {
        int32_t callbackError = stateCallbackResult != AV_SCREEN_CAPTURE_ERR_OK
            ? static_cast<int32_t>(stateCallbackResult)
            : static_cast<int32_t>(errorCallbackResult);
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configureCallbacks", callbackError);
    }

    OH_AVSCREEN_CAPTURE_ErrCode initResult = OH_AVScreenCapture_Init(gCapture, config);
    if (initResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "initialize", static_cast<int32_t>(initResult));
    }
    OH_AVSCREEN_CAPTURE_ErrCode frameRateResult = OH_AVScreenCapture_SetMaxVideoFrameRate(gCapture, frameRate);
    if (frameRateResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configureFrameRate", static_cast<int32_t>(frameRateResult));
    }
    // 本产品不采集麦克风或系统声音，显式关闭麦克风可避免产生无关权限请求。
    OH_AVScreenCapture_SetMicrophoneEnabled(gCapture, false);
    // 允许系统在横竖屏切换后旋转编码画布，接收端再依据参数集更新窗口比例。
    OH_AVScreenCapture_SetCanvasRotation(gCapture, true);

    OH_AVErrCode encoderStartResult = OH_VideoEncoder_Start(gEncoder);
    if (encoderStartResult != AV_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "startEncoder", static_cast<int32_t>(encoderStartResult));
    }
    gEncoderStarted = true;

    OH_AVSCREEN_CAPTURE_ErrCode startResult =
        OH_AVScreenCapture_StartScreenCaptureWithSurface(gCapture, gEncoderSurface);
    if (startResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "startCaptureSurface", static_cast<int32_t>(startResult));
    }
    gCapturing.store(true);
    return CreateStartResult(env, true, "started", AV_SCREEN_CAPTURE_ERR_OK);
}

napi_value StopCapture(napi_env env, napi_callback_info)
{
    std::lock_guard<std::mutex> lock(gCaptureMutex);
    ReleaseCaptureLocked();
    PublishState(100, "screen_capture_stopped_by_app");
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value IsCapturing(napi_env env, napi_callback_info)
{
    napi_value result;
    napi_get_boolean(env, gCapturing.load(), &result);
    return result;
}

napi_value IsConfigurationSupported(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t width = 0;
    int32_t height = 0;
    int32_t frameRate = 0;
    if (argc != 1 || !ReadInt32(env, argv[0], "width", width) ||
        !ReadInt32(env, argv[0], "height", height) ||
        !ReadInt32(env, argv[0], "frameRate", frameRate)) {
        napi_throw_type_error(env, "ERR_INVALID_CAPTURE_OPTIONS", "投屏能力查询参数不完整");
        return nullptr;
    }

    OH_AVCapability *capability = OH_AVCodec_GetCapabilityByCategory(
        OH_AVCODEC_MIMETYPE_VIDEO_AVC, true, HARDWARE);
    bool supported = capability != nullptr &&
        OH_AVCapability_IsVideoSizeSupported(capability, width, height) &&
        OH_AVCapability_AreVideoSizeAndFrameRateSupported(capability, width, height, frameRate);
    napi_value result;
    napi_get_boolean(env, supported, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"onFrame", nullptr, OnFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onState", nullptr, OnState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCapture", nullptr, StartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, StopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCapturing", nullptr, IsCapturing, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isConfigurationSupported", nullptr, IsConfigurationSupported, nullptr, nullptr, nullptr,
            napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    napi_add_env_cleanup_hook(env, CleanupEnvironment, nullptr);
    return exports;
}

} // 匿名命名空间

static napi_module gModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "hmtrans_cast",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterHMTransCastModule()
{
    napi_module_register(&gModule);
}
