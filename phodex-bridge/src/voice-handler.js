// FILE: voice-handler.js
// Purpose: Handles bridge-owned voice transcription requests without exposing auth tokens to iPhone.
// Layer: Bridge handler
// Exports: createVoiceHandler, resolveVoiceAuth
// Depends on: global fetch/FormData/Blob, local codex app-server auth via sendCodexRequest

const OPENAI_TRANSCRIPTIONS_URL = "https://api.openai.com/v1/audio/transcriptions";
const CHATGPT_TRANSCRIPTIONS_URL = "https://chatgpt.com/backend-api/transcribe";
const DEFAULT_TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe";
const MAX_AUDIO_BYTES = 10 * 1024 * 1024;
const MAX_DURATION_MS = 120_000;

function createVoiceHandler({
  sendCodexRequest,
  fetchImpl = globalThis.fetch,
  FormDataImpl = globalThis.FormData,
  BlobImpl = globalThis.Blob,
  logPrefix = "[remodex]",
  env = process.env,
} = {}) {
  function handleVoiceRequest(rawMessage, sendResponse) {
    let parsed;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
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
      env,
    })
      .then((result) => {
        sendResponse(JSON.stringify({ id, result }));
      })
      .catch((error) => {
        console.error(`${logPrefix} voice transcription failed: ${error.message}`);
        sendResponse(JSON.stringify({
          id,
          error: {
            code: -32000,
            message: error.userMessage || error.message || "Voice transcription failed.",
            data: {
              errorCode: error.errorCode || "voice_transcription_failed",
            },
          },
        }));
      });

    return true;
  }

  return {
    handleVoiceRequest,
  };
}

// ─── Audio validation helpers ───────────────────────────────

// Validates iPhone-owned audio input and proxies it to the official transcription endpoint.
async function transcribeVoice(
  params,
  { sendCodexRequest, fetchImpl, FormDataImpl, BlobImpl, env = process.env }
) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }
  if (typeof fetchImpl !== "function" || !FormDataImpl || !BlobImpl) {
    throw voiceError("transcription_unavailable", "Voice transcription is unavailable on this bridge.");
  }

  const mimeType = readString(params.mimeType);
  if (mimeType !== "audio/wav") {
    throw voiceError("unsupported_mime_type", "Only WAV audio is supported for voice transcription.");
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
    throw voiceError("duration_too_long", "Voice messages are limited to 120 seconds.");
  }

  const audioBuffer = decodeAudioBase64(params.audioBase64);
  if (audioBuffer.length > MAX_AUDIO_BYTES) {
    throw voiceError("audio_too_large", "Voice messages are limited to 10 MB.");
  }
  const wavInfo = readWavInfo(audioBuffer);
  if (!wavInfo) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
  }
  if (wavInfo.audioFormat !== 1
    || wavInfo.channelCount !== 1
    || wavInfo.sampleRateHz !== 24_000
    || wavInfo.bitsPerSample !== 16) {
    throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
  }

  const authContext = await loadAuthContext(sendCodexRequest, { env });
  return requestTranscription({
    authContext,
    audioBuffer,
    mimeType,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    sendCodexRequest,
    env,
  });
}

async function requestTranscription({
  authContext,
  audioBuffer,
  mimeType,
  fetchImpl,
  FormDataImpl,
  BlobImpl,
  sendCodexRequest,
  env,
}) {
  const makeAttempt = async (activeAuthContext) => {
    const formData = new FormDataImpl();
    formData.append("file", new BlobImpl([audioBuffer], { type: mimeType }), "voice.wav");
    if (!activeAuthContext.isChatGPT) {
      formData.append("model", DEFAULT_TRANSCRIPTION_MODEL);
    }

    const headers = {
      Authorization: `Bearer ${activeAuthContext.token}`,
    };

    return fetchImpl(activeAuthContext.transcriptionURL, {
      method: "POST",
      headers,
      body: formData,
    });
  };

  let activeAuthContext = authContext;
  let response = await makeAttempt(activeAuthContext);
  if (response.status === 401 || response.status === 403) {
    activeAuthContext = await loadAuthContext(sendCodexRequest, { env });
    response = await makeAttempt(activeAuthContext);
    if (!response.ok
      && (response.status === 401 || response.status === 403)
      && activeAuthContext.isChatGPT) {
      const apiKeyContext = loadEnvApiKeyAuthContext(env);
      if (apiKeyContext) {
        activeAuthContext = apiKeyContext;
        response = await makeAttempt(activeAuthContext);
      }
    }
  }

  if (!response.ok) {
    let errorMessage = `Transcription failed with status ${response.status}.`;
    try {
      const errorPayload = await response.json();
      const providerMessage = readString(errorPayload?.error?.message) || readString(errorPayload?.message);
      if (providerMessage) {
        errorMessage = providerMessage;
      }
    } catch {
      // Keep the generic message when the provider body is empty or non-JSON.
    }

    if (response.status === 401 || response.status === 403) {
      const message = activeAuthContext.isChatGPT
        ? "Your ChatGPT login has expired. Sign in again."
        : "Your OpenAI API key was rejected. Update the API key on the Mac, then try again.";
      throw voiceError("auth_rejected", message);
    }

    throw voiceError("transcription_failed", errorMessage);
  }

  const payload = await response.json().catch(() => null);
  const text = readString(payload?.text) || readString(payload?.transcript);
  if (!text) {
    throw voiceError("transcription_invalid_response", "The transcription response did not include any text.");
  }

  return { text };
}

// Reads the current bridge-owned auth state from the local codex app-server and refreshes if needed.
async function loadAuthContext(sendCodexRequest, { env = process.env } = {}) {
  const authStatus = await readVoiceAuthStatus(sendCodexRequest);

  const authMethod = readString(authStatus?.authMethod);
  const token = normalizeBearerToken(authStatus?.authToken);
  const isChatGPT = isChatGPTAuthMethod(authMethod);

  if (!token) {
    const apiKeyContext = loadEnvApiKeyAuthContext(env);
    if (apiKeyContext) {
      return apiKeyContext;
    }
    throw voiceError("not_authenticated", "Sign in with ChatGPT or configure an OpenAI API key before using voice transcription.");
  }

  return {
    authMethod,
    token,
    isChatGPT,
    transcriptionURL: isChatGPT ? CHATGPT_TRANSCRIPTIONS_URL : OPENAI_TRANSCRIPTIONS_URL,
  };
}

function loadEnvApiKeyAuthContext(env = process.env) {
  const token = normalizeBearerToken(env?.OPENAI_API_KEY);
  if (!token) {
    return null;
  }

  return {
    authMethod: "apiKey",
    token,
    isChatGPT: false,
    transcriptionURL: OPENAI_TRANSCRIPTIONS_URL,
  };
}

async function readVoiceAuthStatus(sendCodexRequest) {
  try {
    return await sendCodexRequest("getAuthStatus", {
      includeToken: true,
      refreshToken: true,
    });
  } catch (err) {
    console.error(`[remodex] voice auth: getAuthStatus RPC failed: ${err.message}`);
    throw voiceError("auth_unavailable", "Could not read OpenAI auth from the Mac runtime. Is the bridge running?");
  }
}

function decodeAudioBase64(value) {
  const normalized = normalizeBase64(value);
  if (!normalized) {
    throw voiceError("missing_audio", "The voice request did not include any audio.");
  }

  if (!isLikelyBase64(normalized)) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  const audioBuffer = Buffer.from(normalized, "base64");
  if (!audioBuffer.length) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (audioBuffer.toString("base64") !== normalized) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (!hasRiffWaveHeader(audioBuffer)) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
  }

  return audioBuffer;
}

// Keeps the bridge strict about the payload shape so malformed uploads fail before fetch().
function normalizeBase64(value) {
  return typeof value === "string" ? value.replace(/\s+/g, "").trim() : "";
}

function isLikelyBase64(value) {
  return /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

function hasRiffWaveHeader(buffer) {
  return buffer.length >= 44
    && buffer.toString("ascii", 0, 4) === "RIFF"
    && buffer.toString("ascii", 8, 12) === "WAVE";
}

// Parses chunked WAV metadata so extra chunks before fmt/data do not break valid clips.
function readWavInfo(buffer) {
  if (!hasRiffWaveHeader(buffer)) {
    return null;
  }

  let offset = 12;
  let info = null;
  let hasData = false;
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
        bitsPerSample: buffer.readUInt16LE(payloadStart + 14),
      };
    } else if (chunkId === "data") {
      hasData = chunkSize > 0;
    }

    offset = payloadEnd + (chunkSize % 2);
  }

  return info && hasData ? info : null;
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

function readPositiveNumber(value) {
  const numericValue = typeof value === "number" ? value : Number(value);
  return Number.isFinite(numericValue) && numericValue >= 0 ? numericValue : 0;
}

function voiceError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
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
