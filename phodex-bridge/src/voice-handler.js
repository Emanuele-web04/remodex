// FILE: voice-handler.js
// Purpose: Handles bridge-owned voice transcription and prewarm requests without exposing auth tokens to iPhone.
// Layer: Bridge handler
// Exports: createVoiceHandler, resolveVoiceAuth
// Depends on: global fetch/FormData/Blob, local codex app-server auth via sendCodexRequest

const CHATGPT_TRANSCRIPTIONS_URL = "https://chatgpt.com/backend-api/transcribe";
const MAX_AUDIO_BYTES = 10 * 1024 * 1024;
const MAX_DURATION_SECONDS = 150;
const MAX_DURATION_MS = MAX_DURATION_SECONDS * 1_000;
const DEFAULT_TRANSCRIPTION_TIMEOUT_MS = 175_000;
const MAX_DURATION_DRIFT_MS = 2_000;
const AUTH_CACHE_TTL_MS = 60_000;
const PRECONNECT_MIN_INTERVAL_MS = 2_000;
const PRECONNECT_TIMEOUT_MS = 10_000;
// Keep m4a support dormant until a live endpoint probe proves subscription uploads accept it.
const VOICE_AUDIO_FORMATS = ["wav"];
const VOICE_WAV_MIME_TYPE = "audio/wav";
const VOICE_M4A_MIME_TYPE = "audio/mp4";

function createVoiceHandler({
  sendCodexRequest,
  fetchImpl = globalThis.fetch,
  FormDataImpl = globalThis.FormData,
  BlobImpl = globalThis.Blob,
  logPrefix = "[remodex]",
  logger = console,
  transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
} = {}) {
  // Keeps a short-lived auth context plus TLS preconnect so the post-recording
  // transcription request skips the token refresh and handshake round trips.
  const warmState = {
    authPromise: null,
    authLoadedAt: 0,
    lastPreconnectAt: 0,
  };

  function cacheAuthPromise(promise) {
    warmState.authPromise = promise;
    warmState.authLoadedAt = Date.now();
    promise.catch(() => {
      if (warmState.authPromise === promise) {
        warmState.authPromise = null;
      }
    });
    return promise;
  }

  function loadAuth() {
    if (warmState.authPromise && Date.now() - warmState.authLoadedAt < AUTH_CACHE_TTL_MS) {
      return warmState.authPromise;
    }
    return cacheAuthPromise(loadAuthContext(sendCodexRequest, { refreshToken: false }));
  }

  function refreshAuth() {
    return cacheAuthPromise(loadAuthContext(sendCodexRequest, { refreshToken: true }));
  }

  // Opens (or revives) the HTTPS connection to the provider so the upload fetch reuses it.
  function preconnectTranscriptionOrigin() {
    if (typeof fetchImpl !== "function") {
      return;
    }
    const now = Date.now();
    if (now - warmState.lastPreconnectAt < PRECONNECT_MIN_INTERVAL_MS) {
      return;
    }
    warmState.lastPreconnectAt = now;

    const controller = typeof AbortController === "function" ? new AbortController() : null;
    const timeoutID = controller
      ? setTimeout(() => controller.abort(new Error("voice preconnect timed out")), PRECONNECT_TIMEOUT_MS)
      : null;
    timeoutID?.unref?.();

    Promise.resolve()
      .then(() => fetchImpl(new URL("/", CHATGPT_TRANSCRIPTIONS_URL).toString(), {
        method: "HEAD",
        signal: controller?.signal,
      }))
      .then((response) => {
        response?.body?.cancel?.()?.catch?.(() => {});
      })
      .catch(() => {})
      .finally(() => {
        if (timeoutID) {
          clearTimeout(timeoutID);
        }
      });
  }

  function handlePrewarmRequest(id, sendResponse) {
    preconnectTranscriptionOrigin();
    loadAuth().catch(() => {});
    logVoiceEvent(logger, "log", logPrefix, "prewarm requested");
    if (id != null) {
      sendResponse(JSON.stringify({ id, result: { ok: true, formats: VOICE_AUDIO_FORMATS } }));
    }
  }

  function handleVoiceRequest(rawMessage, sendResponse, parsedMessage = null) {
    const parsed = parsedMessage || parseJsonMessage(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method === "voice/prewarm") {
      handlePrewarmRequest(parsed.id, sendResponse);
      return true;
    }
    if (method !== "voice/transcribe") {
      return false;
    }

    const id = parsed.id;
    const params = parsed.params || {};

    transcribeVoice(params, {
      sendCodexRequest,
      fetchImpl,
      FormDataImpl,
      BlobImpl,
      logger,
      logPrefix,
      transcriptionTimeoutMs,
      loadAuth,
      refreshAuth,
    })
      .then((result) => {
        sendResponse(JSON.stringify({ id, result }));
      })
      .catch((error) => {
        logVoiceEvent(logger, "error", logPrefix, "failed", {
          errorCode: error.errorCode || "voice_transcription_failed",
        });
        sendResponse(JSON.stringify({
          id,
          error: {
            code: -32000,
            message: error.userMessage || error.message || "Voice transcription failed.",
            data: voiceErrorData(error),
          },
        }));
      });

    return true;
  }

  return {
    handleVoiceRequest,
  };
}

function parseJsonMessage(rawMessage) {
  try {
    return JSON.parse(rawMessage);
  } catch {
    return null;
  }
}

// ─── Audio validation helpers ───────────────────────────────

// Validates iPhone-owned audio input and proxies it to the official transcription endpoint.
async function transcribeVoice(
  params,
  {
    sendCodexRequest,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    logger = console,
    logPrefix = "[remodex]",
    transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
    loadAuth = () => loadAuthContext(sendCodexRequest, { refreshToken: false }),
    refreshAuth = () => loadAuthContext(sendCodexRequest, { refreshToken: true }),
  }
) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }
  if (typeof fetchImpl !== "function" || !FormDataImpl || !BlobImpl) {
    throw voiceError("transcription_unavailable", "Voice transcription is unavailable on this bridge.");
  }

  const mimeType = readString(params.mimeType);
  if (!isSupportedVoiceMimeType(mimeType)) {
    throw voiceError("unsupported_mime_type", "Only WAV or M4A audio is supported for voice transcription.");
  }

  const sampleRateHz = readPositiveNumber(params.sampleRateHz);
  if (sampleRateHz !== 24_000) {
    throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
  }

  const durationMs = readPositiveNumber(params.durationMs);
  if (durationMs <= 0) {
    throw voiceError("invalid_duration", "Voice messages must include a positive duration.");
  }
  if (durationMs > MAX_DURATION_MS) {
    throw voiceError("duration_too_long", `Voice messages are limited to ${MAX_DURATION_SECONDS} seconds.`);
  }

  const audioBuffer = decodeAudioBase64(params.audioBase64);
  if (audioBuffer.length > MAX_AUDIO_BYTES) {
    throw voiceError("audio_too_large", "Voice messages are limited to 10 MB.");
  }
  const audioInfo = readVoiceAudioInfo(audioBuffer, mimeType);
  const actualDurationMs = audioInfo.durationMs;
  if (!Number.isFinite(actualDurationMs) || actualDurationMs <= 0) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid audio file.");
  }
  if (actualDurationMs > MAX_DURATION_MS) {
    throw voiceError("duration_too_long", `Voice messages are limited to ${MAX_DURATION_SECONDS} seconds.`);
  }
  if (actualDurationMs > durationMs + MAX_DURATION_DRIFT_MS) {
    throw voiceError("duration_mismatch", "The recorded audio duration did not match the voice request.");
  }

  logVoiceEvent(logger, "log", logPrefix, "request received", {
    durationMs,
    actualDurationMs: Math.round(actualDurationMs),
    audioBytes: audioBuffer.length,
  });

  const authContext = await loadAuth();
  return requestTranscription({
    authContext,
    audioBuffer,
    mimeType,
    filename: audioInfo.filename,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    refreshAuth,
    logger,
    logPrefix,
    transcriptionTimeoutMs,
  });
}

// Posts the validated clip to the active transcription provider and logs only safe metadata.
async function requestTranscription({
  authContext,
  audioBuffer,
  mimeType,
  filename = "voice.wav",
  fetchImpl,
  FormDataImpl,
  BlobImpl,
  refreshAuth,
  logger = console,
  logPrefix = "[remodex]",
  transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
}) {
  const makeAttempt = async (activeAuthContext, attempt) => {
    logVoiceEvent(logger, "log", logPrefix, "auth selected", {
      attempt,
      source: activeAuthContext.authSource,
      method: activeAuthContext.authMethodClass,
      provider: activeAuthContext.provider,
    });

    const formData = new FormDataImpl();
    formData.append("file", new BlobImpl([audioBuffer], { type: mimeType }), filename);

    const headers = {
      Authorization: `Bearer ${activeAuthContext.token}`,
    };

    const timeoutMs = Number.isFinite(transcriptionTimeoutMs)
      ? Math.max(0, Math.floor(transcriptionTimeoutMs))
      : DEFAULT_TRANSCRIPTION_TIMEOUT_MS;
    const controller = typeof AbortController === "function" && timeoutMs > 0
      ? new AbortController()
      : null;
    const timeoutID = controller
      ? setTimeout(() => {
        controller.abort(createTranscriptionTimeoutError(timeoutMs));
      }, timeoutMs)
      : null;
    timeoutID?.unref?.();

    let response;
    try {
      response = await fetchImpl(activeAuthContext.transcriptionURL, {
        method: "POST",
        headers,
        body: formData,
        signal: controller?.signal,
      });
    } catch (error) {
      if (isAbortError(error, controller)) {
        logVoiceEvent(logger, "warn", logPrefix, "provider status", {
          attempt,
          provider: activeAuthContext.provider,
          status: "timeout",
          ok: false,
        });
        throw voiceError(
          "transcription_timeout",
          "Voice transcription timed out. Try a shorter clip or retry when the connection is stable.",
          { provider: activeAuthContext.provider }
        );
      }

      logVoiceEvent(logger, "warn", logPrefix, "provider status", {
        attempt,
        provider: activeAuthContext.provider,
        status: "network_error",
        ok: false,
      });
      throw voiceError(
        "transcription_network_error",
        "Voice transcription could not reach the provider.",
        { provider: activeAuthContext.provider }
      );
    } finally {
      if (timeoutID) {
        clearTimeout(timeoutID);
      }
    }

    logVoiceEvent(logger, response.ok ? "log" : "warn", logPrefix, "provider status", {
      attempt,
      provider: activeAuthContext.provider,
      status: response.status,
      ok: Boolean(response.ok),
    });
    return response;
  };

  let activeAuthContext = authContext;
  let attempt = 1;
  let response = await makeAttempt(activeAuthContext, attempt);
  if (response.status === 401 || response.status === 403) {
    // First attempt runs on a cached/non-refreshed token, so force a refresh here.
    activeAuthContext = await refreshAuth();
    attempt += 1;
    response = await makeAttempt(activeAuthContext, attempt);
  }

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw voiceError(
        "auth_rejected",
        "Your ChatGPT login has expired. Sign in again.",
        { provider: activeAuthContext.provider }
      );
    }

    throw voiceError(
      "transcription_failed",
      `Voice transcription failed with provider status ${response.status}.`,
      { provider: activeAuthContext.provider, status: response.status }
    );
  }

  const payload = await response.json().catch(() => null);
  const text = readString(payload?.text) || readString(payload?.transcript);
  if (!text) {
    throw voiceError("transcription_invalid_response", "The transcription response did not include any text.");
  }

  logVoiceEvent(logger, "log", logPrefix, "success", {
    provider: activeAuthContext.provider,
    status: response.status,
    textLength: text.length,
  });

  return { text };
}

// Reads the current bridge-owned ChatGPT auth state; refresh is reserved for 401/403 retries.
async function loadAuthContext(sendCodexRequest, { refreshToken = false } = {}) {
  const authStatus = await readVoiceAuthStatus(sendCodexRequest, { refreshToken });

  const authMethod = readString(authStatus?.authMethod);
  const token = normalizeBearerToken(authStatus?.authToken);
  const isChatGPT = isChatGPTAuthMethod(authMethod);

  if (!token) {
    throw voiceError("not_authenticated", "Sign in with ChatGPT before using voice transcription.");
  }

  if (!isChatGPT) {
    throw voiceError("not_chatgpt", "Voice transcription requires a ChatGPT account.");
  }

  return {
    authMethod,
    authSource: "mac_runtime",
    authMethodClass: "chatgpt",
    provider: "chatgpt",
    token,
    transcriptionURL: CHATGPT_TRANSCRIPTIONS_URL,
  };
}

async function readVoiceAuthStatus(sendCodexRequest, { refreshToken = true } = {}) {
  try {
    return await sendCodexRequest("getAuthStatus", {
      includeToken: true,
      refreshToken,
    });
  } catch {
    console.error("[remodex] voice auth: getAuthStatus RPC failed");
    throw voiceError("auth_unavailable", "Could not read ChatGPT auth from the Mac runtime. Is the bridge running?");
  }
}

function decodeAudioBase64(value) {
  const normalized = normalizeBase64(value);
  if (!normalized) {
    throw voiceError("missing_audio", "The voice request did not include any audio.");
  }

  const audioBuffer = Buffer.from(normalized, "base64");
  if (!audioBuffer.length) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (audioBuffer.toString("base64") !== normalized) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  return audioBuffer;
}

// Keeps the bridge strict about the payload shape so malformed uploads fail before fetch().
function normalizeBase64(value) {
  return typeof value === "string" ? value.replace(/\s+/g, "").trim() : "";
}

function hasRiffWaveHeader(buffer) {
  return buffer.length >= 44
    && buffer.toString("ascii", 0, 4) === "RIFF"
    && buffer.toString("ascii", 8, 12) === "WAVE";
}

function isSupportedVoiceMimeType(mimeType) {
  return mimeType === VOICE_WAV_MIME_TYPE || mimeType === VOICE_M4A_MIME_TYPE;
}

function readVoiceAudioInfo(buffer, mimeType) {
  if (mimeType === VOICE_WAV_MIME_TYPE) {
    const wavInfo = readWavInfo(buffer);
    if (!wavInfo) {
      throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
    }
    if (!isSupportedVoiceWavFormat(wavInfo)) {
      throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
    }
    if (!hasConsistentVoiceWavLayout(wavInfo)) {
      throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
    }
    return {
      durationMs: wavDurationMs(wavInfo),
      filename: "voice.wav",
    };
  }

  const m4aInfo = readM4AInfo(buffer);
  if (!m4aInfo) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid M4A file.");
  }
  return {
    durationMs: m4aInfo.durationMs,
    filename: "voice.m4a",
  };
}

// Parses chunked WAV metadata so extra chunks before fmt/data do not break valid clips.
function readWavInfo(buffer) {
  if (!hasRiffWaveHeader(buffer)) {
    return null;
  }

  let offset = 12;
  let info = null;
  let hasData = false;
  let dataByteCount = 0;
  while (offset + 8 <= buffer.length) {
    const chunkId = buffer.toString("ascii", offset, offset + 4);
    const chunkSize = buffer.readUInt32LE(offset + 4);
    const payloadStart = offset + 8;
    const payloadEnd = payloadStart + chunkSize;
    if (payloadEnd > buffer.length) {
      return null;
    }

    if (chunkId === "fmt ") {
      if (chunkSize < 16) {
        return null;
      }
      info = {
        audioFormat: buffer.readUInt16LE(payloadStart),
        channelCount: buffer.readUInt16LE(payloadStart + 2),
        sampleRateHz: buffer.readUInt32LE(payloadStart + 4),
        byteRate: buffer.readUInt32LE(payloadStart + 8),
        blockAlign: buffer.readUInt16LE(payloadStart + 12),
        bitsPerSample: buffer.readUInt16LE(payloadStart + 14),
      };
    } else if (chunkId === "data") {
      hasData = chunkSize > 0;
      dataByteCount = chunkSize;
    }

    offset = payloadEnd + (chunkSize % 2);
  }

  if (info && hasData) {
    info.dataByteCount = dataByteCount;
    return info;
  }
  return null;
}

function isSupportedVoiceWavFormat(wavInfo) {
  return wavInfo.audioFormat === 1
    && wavInfo.channelCount === 1
    && wavInfo.sampleRateHz === 24_000
    && wavInfo.bitsPerSample === 16;
}

// Rejects forged WAV layout fields before using data length for duration checks.
function hasConsistentVoiceWavLayout(wavInfo) {
  return wavInfo.blockAlign === expectedVoiceWavBlockAlign(wavInfo)
    && wavInfo.byteRate === expectedVoiceWavByteRate(wavInfo);
}

function expectedVoiceWavBlockAlign(wavInfo) {
  return wavInfo.channelCount * (wavInfo.bitsPerSample / 8);
}

function expectedVoiceWavByteRate(wavInfo) {
  return wavInfo.sampleRateHz * expectedVoiceWavBlockAlign(wavInfo);
}

function wavDurationMs(wavInfo) {
  const byteRate = expectedVoiceWavByteRate(wavInfo);
  if (!Number.isFinite(byteRate) || byteRate <= 0) {
    return NaN;
  }

  return (Number(wavInfo.dataByteCount || 0) / byteRate) * 1_000;
}

// Parses the MP4/M4A container enough to validate Remodex-generated AAC clips
// before proxying them to ChatGPT.
function readM4AInfo(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 16) {
    return null;
  }

  let hasM4ABrand = false;
  let hasMediaData = false;
  let durationMs = NaN;
  let audioTrackInfo = null;
  for (const box of readMp4Boxes(buffer, 0, buffer.length)) {
    if (box.type === "ftyp") {
      hasM4ABrand = isM4AFileTypeBox(buffer, box);
    } else if (box.type === "mdat") {
      hasMediaData = box.payloadEnd > box.payloadStart;
    } else if (box.type === "moov") {
      durationMs = readMovieDurationMs(buffer, box.payloadStart, box.payloadEnd);
      audioTrackInfo = readAudioTrackInfo(buffer, box.payloadStart, box.payloadEnd);
    }
  }

  if (!hasM4ABrand
    || !hasMediaData
    || !Number.isFinite(durationMs)
    || durationMs <= 0
    || !isSupportedM4AAudioTrack(audioTrackInfo)) {
    return null;
  }
  return { durationMs: Math.max(durationMs, audioTrackInfo.mdhdDurationMs) };
}

function* readMp4Boxes(buffer, start, end) {
  let offset = start;
  while (offset + 8 <= end) {
    const size32 = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    let headerSize = 8;
    let size = size32;
    if (size32 === 1) {
      if (offset + 16 > end) {
        return;
      }
      const size64 = buffer.readBigUInt64BE(offset + 8);
      if (size64 > BigInt(Number.MAX_SAFE_INTEGER)) {
        return;
      }
      size = Number(size64);
      headerSize = 16;
    } else if (size32 === 0) {
      size = end - offset;
    }

    if (size < headerSize || offset + size > end) {
      return;
    }

    yield {
      type,
      start: offset,
      end: offset + size,
      payloadStart: offset + headerSize,
      payloadEnd: offset + size,
    };
    offset += size;
  }
}

function isM4AFileTypeBox(buffer, box) {
  if (box.payloadEnd - box.payloadStart < 8) {
    return false;
  }
  const brands = [
    buffer.toString("ascii", box.payloadStart, box.payloadStart + 4),
  ];
  for (let offset = box.payloadStart + 8; offset + 4 <= box.payloadEnd; offset += 4) {
    brands.push(buffer.toString("ascii", offset, offset + 4));
  }
  return brands.includes("M4A ");
}

function readMovieDurationMs(buffer, start, end) {
  for (const box of readMp4Boxes(buffer, start, end)) {
    if (box.type !== "mvhd") {
      continue;
    }
    return readMovieHeaderDurationMs(buffer, box.payloadStart, box.payloadEnd);
  }
  return NaN;
}

function readAudioTrackInfo(buffer, start, end) {
  for (const box of readMp4Boxes(buffer, start, end)) {
    if (box.type !== "trak") {
      continue;
    }
    const trackInfo = readTrackInfo(buffer, box.payloadStart, box.payloadEnd);
    if (trackInfo.handlerType === "soun") {
      return trackInfo;
    }
  }
  return null;
}

function readTrackInfo(buffer, start, end) {
  let mdhdTimescale = NaN;
  let mdhdDurationMs = NaN;
  let handlerType = "";
  let sampleEntryInfo = null;
  for (const box of readMp4Boxes(buffer, start, end)) {
    if (box.type !== "mdia") {
      continue;
    }
    for (const mediaBox of readMp4Boxes(buffer, box.payloadStart, box.payloadEnd)) {
      if (mediaBox.type === "mdhd") {
        const mediaHeader = readMediaHeaderInfo(buffer, mediaBox.payloadStart, mediaBox.payloadEnd);
        mdhdTimescale = mediaHeader.timescale;
        mdhdDurationMs = mediaHeader.durationMs;
      } else if (mediaBox.type === "hdlr") {
        handlerType = readHandlerType(buffer, mediaBox.payloadStart, mediaBox.payloadEnd);
      } else if (mediaBox.type === "minf") {
        sampleEntryInfo = readAudioSampleEntryInfo(buffer, mediaBox.payloadStart, mediaBox.payloadEnd);
      }
    }
  }
  return { mdhdTimescale, mdhdDurationMs, handlerType, sampleEntryInfo };
}

function readMediaHeaderInfo(buffer, start, end) {
  if (start + 4 > end) {
    return { timescale: NaN, durationMs: NaN };
  }
  const version = buffer.readUInt8(start);
  if (version === 0) {
    if (start + 20 > end) {
      return { timescale: NaN, durationMs: NaN };
    }
    const timescale = buffer.readUInt32BE(start + 12);
    const duration = buffer.readUInt32BE(start + 16);
    return { timescale, durationMs: movieDurationMs(timescale, duration) };
  }
  if (version === 1) {
    if (start + 32 > end) {
      return { timescale: NaN, durationMs: NaN };
    }
    const timescale = buffer.readUInt32BE(start + 20);
    const duration = buffer.readBigUInt64BE(start + 24);
    if (duration > BigInt(Number.MAX_SAFE_INTEGER)) {
      return { timescale: NaN, durationMs: NaN };
    }
    return { timescale, durationMs: movieDurationMs(timescale, Number(duration)) };
  }
  return { timescale: NaN, durationMs: NaN };
}

function readHandlerType(buffer, start, end) {
  if (start + 12 > end) {
    return "";
  }
  return buffer.toString("ascii", start + 8, start + 12);
}

function readAudioSampleEntryInfo(buffer, start, end) {
  for (const minfBox of readMp4Boxes(buffer, start, end)) {
    if (minfBox.type !== "stbl") {
      continue;
    }
    for (const stblBox of readMp4Boxes(buffer, minfBox.payloadStart, minfBox.payloadEnd)) {
      if (stblBox.type !== "stsd") {
        continue;
      }
      const sampleEntry = readFirstSampleEntry(buffer, stblBox.payloadStart, stblBox.payloadEnd);
      if (sampleEntry) {
        return sampleEntry;
      }
    }
  }
  return null;
}

function readFirstSampleEntry(buffer, start, end) {
  if (start + 8 > end) {
    return null;
  }
  const entryCount = buffer.readUInt32BE(start + 4);
  if (entryCount < 1) {
    return null;
  }
  const [sampleEntry] = readMp4Boxes(buffer, start + 8, end);
  if (!sampleEntry || sampleEntry.type !== "mp4a" || sampleEntry.payloadStart + 28 > sampleEntry.payloadEnd) {
    return null;
  }
  return {
    codec: sampleEntry.type,
    channelCount: buffer.readUInt16BE(sampleEntry.payloadStart + 16),
    sampleRateHz: buffer.readUInt32BE(sampleEntry.payloadStart + 24) >>> 16,
  };
}

function isSupportedM4AAudioTrack(trackInfo) {
  return trackInfo?.handlerType === "soun"
    && trackInfo.mdhdTimescale === 24_000
    && Number.isFinite(trackInfo.mdhdDurationMs)
    && trackInfo.mdhdDurationMs > 0
    && trackInfo.sampleEntryInfo?.codec === "mp4a"
    && trackInfo.sampleEntryInfo?.channelCount === 1
    && trackInfo.sampleEntryInfo?.sampleRateHz === 24_000;
}

function readMovieHeaderDurationMs(buffer, start, end) {
  if (start + 4 > end) {
    return NaN;
  }
  const version = buffer.readUInt8(start);
  if (version === 0) {
    if (start + 20 > end) {
      return NaN;
    }
    const timescale = buffer.readUInt32BE(start + 12);
    const duration = buffer.readUInt32BE(start + 16);
    return movieDurationMs(timescale, duration);
  }
  if (version === 1) {
    if (start + 32 > end) {
      return NaN;
    }
    const timescale = buffer.readUInt32BE(start + 20);
    const duration = buffer.readBigUInt64BE(start + 24);
    if (duration > BigInt(Number.MAX_SAFE_INTEGER)) {
      return NaN;
    }
    return movieDurationMs(timescale, Number(duration));
  }
  return NaN;
}

function movieDurationMs(timescale, duration) {
  if (!Number.isFinite(timescale) || timescale <= 0 || !Number.isFinite(duration) || duration <= 0) {
    return NaN;
  }
  return (duration / timescale) * 1_000;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizeBearerToken(value) {
  const token = readString(value);
  if (!token) {
    return null;
  }
  const match = token.match(/^bearer\s+(.+)$/i);
  return match ? match[1].trim() : token;
}

function isChatGPTAuthMethod(value) {
  const normalized = readString(value)?.toLowerCase().replace(/[^a-z0-9]/g, "") || "";
  return normalized.includes("chatgpt");
}

// Formats fixed safe fields only; callers must pass classifications, counts, and statuses.
function logVoiceEvent(logger, level, logPrefix, event, fields = {}) {
  const writer = resolveLogWriter(logger, level);
  const details = Object.entries(fields)
    .map(([key, value]) => `${key}=${formatLogValue(value)}`)
    .join(" ");
  writer(`${logPrefix} voice transcribe ${event}${details ? ` ${details}` : ""}`);
}

function resolveLogWriter(logger, level) {
  if (typeof logger?.[level] === "function") {
    return logger[level].bind(logger);
  }
  if (level === "warn" && typeof logger?.log === "function") {
    return logger.log.bind(logger);
  }
  if (level === "error" && typeof logger?.warn === "function") {
    return logger.warn.bind(logger);
  }
  if (typeof console[level] === "function") {
    return console[level].bind(console);
  }
  return console.log.bind(console);
}

function formatLogValue(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  return String(value).replace(/[^a-zA-Z0-9_.:-]/g, "_");
}

function readPositiveNumber(value) {
  const numericValue = typeof value === "number" ? value : Number(value);
  return Number.isFinite(numericValue) && numericValue >= 0 ? numericValue : 0;
}

function createTranscriptionTimeoutError(timeoutMs) {
  const error = new Error(`Voice transcription timed out after ${timeoutMs}ms`);
  error.name = "AbortError";
  error.code = "voice_transcription_timeout";
  return error;
}

function isAbortError(error, controller) {
  return Boolean(controller?.signal?.aborted)
    || error?.name === "AbortError"
    || error?.code === "ABORT_ERR"
    || error?.code === "voice_transcription_timeout";
}

function voiceErrorData(error) {
  const data = {
    errorCode: error.errorCode || "voice_transcription_failed",
  };
  if (error.provider === "chatgpt") {
    data.provider = error.provider;
  }
  if (Number.isInteger(error.status)) {
    data.status = error.status;
  }
  return data;
}

function voiceError(errorCode, userMessage, details = {}) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  if (details.provider === "chatgpt") {
    error.provider = details.provider;
  }
  if (Number.isInteger(details.status)) {
    error.status = details.status;
  }
  return error;
}

// Serves older phone builds that upload directly to ChatGPT with a Mac-owned token.
async function resolveVoiceAuth(sendCodexRequest) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }

  const authStatus = await readVoiceAuthStatus(sendCodexRequest);
  const authMethod = readString(authStatus?.authMethod);
  const token = normalizeBearerToken(authStatus?.authToken);
  const isChatGPT = isChatGPTAuthMethod(authMethod);

  if (isChatGPT && token) {
    return { token };
  }

  if (!token) {
    throw voiceError("token_missing", "No ChatGPT session token available. Sign in to ChatGPT on the Mac.");
  }

  throw voiceError("not_chatgpt", "Voice transcription requires a ChatGPT account.");
}

module.exports = {
  createVoiceHandler,
  resolveVoiceAuth,
};
