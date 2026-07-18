import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { stringToArrayBuffer, toHex } from './Bytes'
import {
  FileMeta,
  PairingChallenge,
  PairingConfirmation,
  PairingRequest,
  UnpairRequest,
  createPairingRequest,
  createUnpairRequest,
  fileMetaAuthenticationText,
  unpairAuthenticationText,
} from './Protocol'

export const HMTRANS_SECURITY_VERSION: number = 1

export interface PairingInitiatorOptions {
  requesterDeviceId: string
  requesterName: string
  requesterPlatform: string
  requesterSystemVersion: string
  requesterIP: string
  requesterPort: number
  requesterFingerprint: string
  targetDeviceId: string
  targetFingerprint: string
  code: string
}

export interface PairingInitiatorAnswer {
  confirmation: PairingConfirmation
  sharedSecret: string
}

/** 长期主密钥只由本次 X25519 结果派生，不会作为 JSON 字段在局域网中传输。 */
export class PairingInitiatorSession {
  readonly request: PairingRequest
  private keyPair: cryptoFramework.KeyPair
  private code: string

  constructor(options: PairingInitiatorOptions) {
    const code = options.code.replace(/\D/g, '')
    if (code.length !== 6) throw new Error('请输入六位配对码')
    this.code = code
    this.keyPair = cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPairSync()
    const publicKey = base64Encode(this.keyPair.pubKey.getEncoded().data)
    this.request = createPairingRequest(
      options.requesterDeviceId,
      options.requesterName,
      options.requesterPlatform,
      options.requesterSystemVersion,
      options.requesterIP,
      options.requesterPort,
      options.requesterFingerprint,
      options.targetDeviceId,
      options.targetFingerprint,
      util.generateRandomUUID(false).toLowerCase(),
      publicKey,
      HMTRANS_SECURITY_VERSION,
    )
  }

  answer(challenge: PairingChallenge): PairingInitiatorAnswer {
    if (!challenge.accepted || challenge.requestId !== this.request.requestId ||
      challenge.securityVersion !== HMTRANS_SECURITY_VERSION) {
      throw new Error(challenge.reason ?? '配对握手被拒绝')
    }
    const shared = x25519Secret(this.keyPair, challenge.responderPublicKey)
    const transcript = pairingTranscript(this.request, challenge.responderPublicKey)
    const authKey = pairingAuthenticationKey(shared, this.code, transcript)
    const expected = hmacHex(authKey, `responder|${transcript}`)
    if (!secureHexEquals(challenge.proof, expected)) throw new Error('配对码错误或握手身份不匹配')
    return {
      confirmation: {
        type: 'pairing_confirmation',
        requestId: this.request.requestId,
        proof: hmacHex(authKey, `requester|${transcript}`),
      },
      sharedSecret: pairingMasterSecret(shared, authKey, transcript),
    }
  }
}

export class PairingResponderSession {
  readonly challenge: PairingChallenge
  readonly sharedSecret: string
  private expectedProof: string

  constructor(request: PairingRequest, codeValue: string) {
    const code = codeValue.replace(/\D/g, '')
    if (code.length !== 6 || request.securityVersion !== HMTRANS_SECURITY_VERSION) {
      throw new Error('无效安全配对请求')
    }
    const keyPair = cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPairSync()
    const responderPublicKey = base64Encode(keyPair.pubKey.getEncoded().data)
    const shared = x25519Secret(keyPair, request.requesterPublicKey)
    const transcript = pairingTranscript(request, responderPublicKey)
    const authKey = pairingAuthenticationKey(shared, code, transcript)
    this.challenge = {
      type: 'pairing_challenge',
      accepted: true,
      requestId: request.requestId,
      responderPublicKey,
      proof: hmacHex(authKey, `responder|${transcript}`),
      securityVersion: HMTRANS_SECURITY_VERSION,
      reason: null,
    }
    this.expectedProof = hmacHex(authKey, `requester|${transcript}`)
    this.sharedSecret = pairingMasterSecret(shared, authKey, transcript)
  }

  accepts(confirmation: PairingConfirmation): boolean {
    return confirmation.requestId === this.challenge.requestId &&
      secureHexEquals(confirmation.proof, this.expectedProof)
  }
}

/** 用 HKDF 为不同协议用途派生独立的 256 位子密钥。 */
export function derivePurposeKey(secretHex: string, purpose: string, context: string = ''): Uint8Array {
  const master = hexToBytes(secretHex)
  if (master.length !== 32) throw new Error('该配对缺少安全密钥，请删除设备后重新配对')
  return hkdf(master, utf8('HMTrans|security-v1'), utf8(`HMTrans|${purpose}|${context}`))
}

export function authenticationCode(secretHex: string, purpose: string, canonicalText: string,
  context: string = ''): string {
  return hmacHex(derivePurposeKey(secretHex, purpose, context), canonicalText)
}

export function secureHexEquals(lhs: string, rhs: string): boolean {
  const left = hexToBytes(lhs)
  const right = hexToBytes(rhs)
  if (left.length === 0 || left.length !== right.length) return false
  let difference = 0
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index]
  return difference === 0
}

export function authenticateFileMeta(meta: FileMeta, secretHex: string): FileMeta {
  const authenticationId = util.generateRandomUUID(false).toLowerCase()
  const issuedAt = Date.now()
  const unsigned: FileMeta = copyFileMeta(meta, HMTRANS_SECURITY_VERSION, authenticationId, issuedAt, '')
  const signature = authenticationCode(secretHex, 'file-transfer-auth-v1', fileMetaAuthenticationText(unsigned))
  return copyFileMeta(unsigned, HMTRANS_SECURITY_VERSION, authenticationId, issuedAt, signature)
}

export function verifyFileMetaAuthentication(meta: FileMeta, secretHex: string,
  now: number = Date.now(), allowedClockSkewMs: number = 5 * 60 * 1000): boolean {
  if (meta.authenticationVersion !== HMTRANS_SECURITY_VERSION || !meta.authenticationId ||
    !Number.isSafeInteger(meta.issuedAt) || Math.abs(now - (meta.issuedAt ?? 0)) > allowedClockSkewMs ||
    !meta.signature) return false
  const expected = authenticationCode(secretHex, 'file-transfer-auth-v1', fileMetaAuthenticationText(meta))
  return secureHexEquals(meta.signature, expected)
}

export function authenticatedUnpairRequest(requesterDeviceId: string, requesterFingerprint: string,
  targetDeviceId: string, secretHex: string): UnpairRequest {
  const requestId = util.generateRandomUUID(false).toLowerCase()
  const issuedAt = Date.now()
  const unsigned = createUnpairRequest(requesterDeviceId, requesterFingerprint, targetDeviceId,
    requestId, issuedAt, '')
  return createUnpairRequest(requesterDeviceId, requesterFingerprint, targetDeviceId,
    requestId, issuedAt, authenticationCode(secretHex, 'unpair-control-auth-v1', unpairAuthenticationText(unsigned)))
}

export function verifyUnpairRequest(request: UnpairRequest, secretHex: string,
  now: number = Date.now(), allowedClockSkewMs: number = 30 * 1000): boolean {
  if (!request.requestId || !Number.isSafeInteger(request.issuedAt) ||
    Math.abs(now - request.issuedAt) > allowedClockSkewMs || !request.signature) return false
  const expected = authenticationCode(secretHex, 'unpair-control-auth-v1', unpairAuthenticationText(request))
  return secureHexEquals(request.signature, expected)
}

function copyFileMeta(meta: FileMeta, authenticationVersion: number, authenticationId: string,
  issuedAt: number, signature: string): FileMeta {
  return {
    type: meta.type, app: meta.app, version: meta.version, transferId: meta.transferId,
    senderDeviceId: meta.senderDeviceId, senderName: meta.senderName, senderPlatform: meta.senderPlatform,
    fileName: meta.fileName, fileSize: meta.fileSize, sha256: meta.sha256, chunkSize: meta.chunkSize,
    totalChunks: meta.totalChunks, resumeSupported: meta.resumeSupported, sourceKind: meta.sourceKind,
    payloadKind: meta.payloadKind, sourceName: meta.sourceName, sourceSize: meta.sourceSize,
    sourceFileCount: meta.sourceFileCount, senderFingerprint: meta.senderFingerprint,
    authenticationVersion, authenticationId, issuedAt, signature,
  }
}

function pairingTranscript(request: PairingRequest, responderPublicKey: string): string {
  return ['HMTrans-pairing-v1', request.requestId, request.requesterDeviceId, request.requesterFingerprint,
    request.targetDeviceId, request.targetFingerprint, request.requesterPublicKey, responderPublicKey].join('|')
}

function x25519Secret(local: cryptoFramework.KeyPair, remotePublicKey: string): Uint8Array {
  try {
    const generator = cryptoFramework.createAsyKeyGenerator('X25519')
    const remote = generator.convertKeySync({ data: base64Decode(remotePublicKey) }, null)
    return cryptoFramework.createKeyAgreement('X25519').generateSecretSync(local.priKey, remote.pubKey).data
  } catch (_) {
    throw new Error('X25519 临时密钥协商失败')
  }
}

function pairingAuthenticationKey(shared: Uint8Array, code: string, transcript: string): Uint8Array {
  const salt = sha256(utf8(`HMTrans|pairing-code|${code}`))
  return hkdf(shared, salt, utf8(`HMTrans|pairing-auth-v1|${transcript}`))
}

function pairingMasterSecret(shared: Uint8Array, authKey: Uint8Array, transcript: string): string {
  return toHex(hkdf(shared, authKey, utf8(`HMTrans|master-secret-v1|${transcript}`)))
}

function hkdf(key: Uint8Array, salt: Uint8Array, info: Uint8Array): Uint8Array {
  try {
    const kdf = cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND')
    const params: cryptoFramework.HKDFSpec = {
      algName: 'HKDF',
      key,
      salt,
      info,
      keySize: 32,
    }
    return kdf.generateSecretSync(params).data
  } catch (_) {
    throw new Error('HKDF 密钥派生失败')
  }
}

function sha256(value: Uint8Array): Uint8Array {
  try {
    const digest = cryptoFramework.createMd('SHA256')
    digest.updateSync({ data: value })
    return digest.digestSync().data
  } catch (_) {
    throw new Error('SHA-256 摘要失败')
  }
}

function hmacHex(keyBytes: Uint8Array, text: string): string {
  try {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC')
    const key = generator.convertKeySync({ data: keyBytes })
    const mac = cryptoFramework.createMac('SHA256')
    mac.initSync(key)
    mac.updateSync({ data: utf8(text) })
    return toHex(mac.doFinalSync().data)
  } catch (_) {
    throw new Error('HMAC-SHA256 认证失败')
  }
}

function utf8(value: string): Uint8Array {
  return new Uint8Array(stringToArrayBuffer(value))
}

function base64Encode(value: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(value)
}

function base64Decode(value: string): Uint8Array {
  return new util.Base64Helper().decodeSync(value)
}

function hexToBytes(value: string): Uint8Array {
  if (!value.length || value.length % 2 !== 0) return new Uint8Array()
  const result = new Uint8Array(value.length / 2)
  for (let index = 0; index < result.length; index++) {
    const byte = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16)
    if (!Number.isFinite(byte)) return new Uint8Array()
    result[index] = byte
  }
  return result
}
