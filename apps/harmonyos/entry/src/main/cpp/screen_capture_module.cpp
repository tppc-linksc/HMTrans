#include <algorithm>
#include <atomic>
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
#include <multimedia/player_framework/native_avscreen_capture.h>

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
std::atomic_bool gCapturing {false};
napi_threadsafe_function gFrameCallback = nullptr;
napi_threadsafe_function gStateCallback = nullptr;

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
    gCapturing.store(false);
    PublishState(errorCode == 0 ? -1 : -std::abs(errorCode), "screen_capture_error");
}

void OnCaptureBuffer(OH_AVScreenCapture *, OH_AVBuffer *buffer,
    OH_AVScreenCaptureBufferType bufferType, int64_t timestamp, void *)
{
    if (!gCapturing.load() || bufferType != OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO ||
        buffer == nullptr || gFrameCallback == nullptr) {
        return;
    }

    OH_AVCodecBufferAttr attr {};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK || attr.size <= 0 || attr.offset < 0) {
        return;
    }
    uint8_t *address = OH_AVBuffer_GetAddr(buffer);
    int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    if (address == nullptr || capacity <= 0 || attr.offset > capacity || attr.size > capacity - attr.offset) {
        return;
    }

    auto *event = new FrameEvent;
    event->bytes.assign(address + attr.offset, address + attr.offset + attr.size);
    event->ptsUs = attr.pts > 0 ? attr.pts : timestamp;
    event->flags = attr.flags;
    // 队列上限为四帧；JS 侧发送跟不上时直接丢弃，避免投屏拖垮文件传输和系统内存。
    if (napi_call_threadsafe_function(gFrameCallback, event, napi_tsfn_nonblocking) != napi_ok) {
        delete event;
    }
}

void ReleaseCaptureLocked()
{
    if (gCapture == nullptr) {
        gCapturing.store(false);
        return;
    }
    gCapturing.store(false);
    OH_AVScreenCapture_StopScreenCapture(gCapture);
    OH_AVScreenCapture_Release(gCapture);
    gCapture = nullptr;
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

    OH_AVScreenCaptureConfig config {};
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ENCODED_STREAM;
    config.audioInfo.micCapInfo.audioSource = OH_SOURCE_INVALID;
    config.audioInfo.innerCapInfo.audioSource = OH_SOURCE_INVALID;
    config.videoInfo.videoCapInfo.videoFrameWidth = width;
    config.videoInfo.videoCapInfo.videoFrameHeight = height;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_ES;
    config.videoInfo.videoEncInfo.videoCodec = OH_H264;
    config.videoInfo.videoEncInfo.videoBitrate = bitrate;
    config.videoInfo.videoEncInfo.videoFrameRate = frameRate;

    OH_AVSCREEN_CAPTURE_ErrCode stateCallbackResult =
        OH_AVScreenCapture_SetStateCallback(gCapture, OnCaptureState, nullptr);
    OH_AVSCREEN_CAPTURE_ErrCode dataCallbackResult =
        OH_AVScreenCapture_SetDataCallback(gCapture, OnCaptureBuffer, nullptr);
    OH_AVSCREEN_CAPTURE_ErrCode errorCallbackResult =
        OH_AVScreenCapture_SetErrorCallback(gCapture, OnCaptureError, nullptr);
    if (stateCallbackResult != AV_SCREEN_CAPTURE_ERR_OK || dataCallbackResult != AV_SCREEN_CAPTURE_ERR_OK ||
        errorCallbackResult != AV_SCREEN_CAPTURE_ERR_OK) {
        int32_t callbackError = stateCallbackResult != AV_SCREEN_CAPTURE_ERR_OK
            ? static_cast<int32_t>(stateCallbackResult)
            : (dataCallbackResult != AV_SCREEN_CAPTURE_ERR_OK
                ? static_cast<int32_t>(dataCallbackResult) : static_cast<int32_t>(errorCallbackResult));
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "configureCallbacks", callbackError);
    }

    OH_AVSCREEN_CAPTURE_ErrCode initResult = OH_AVScreenCapture_Init(gCapture, config);
    if (initResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "initialize", static_cast<int32_t>(initResult));
    }
    // 本产品不采集麦克风或系统声音，显式关闭麦克风可避免产生无关权限请求。
    OH_AVScreenCapture_SetMicrophoneEnabled(gCapture, false);
    // 允许系统在横竖屏切换后旋转编码画布，接收端再依据参数集更新窗口比例。
    OH_AVScreenCapture_SetCanvasRotation(gCapture, true);

    OH_AVSCREEN_CAPTURE_ErrCode startResult = OH_AVScreenCapture_StartScreenCapture(gCapture);
    if (startResult != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCaptureLocked();
        return CreateStartResult(env, false, "start", static_cast<int32_t>(startResult));
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

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"onFrame", nullptr, OnFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onState", nullptr, OnState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCapture", nullptr, StartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, StopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCapturing", nullptr, IsCapturing, nullptr, nullptr, nullptr, napi_default, nullptr},
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
