// FILE: voice-audio.js
// Purpose: Pure WAV and M4A container parsing plus format checks for Remodex voice clips.
// Layer: Bridge helper
// Exports: hasConsistentVoiceWavLayout, isSupportedVoiceWavFormat, readM4AInfo, readWavInfo, wavDurationMs
// Depends on: Buffer

// ─── WAV parsing ─────────────────────────────────────────────────

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

// ─── M4A parsing ─────────────────────────────────────────────────

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
    // CoreAudio writes channelCount=2 in the mp4a sample entry even for mono AAC
    // (the real channel config lives in the esds), so accept both values here.
    && (trackInfo.sampleEntryInfo?.channelCount === 1 || trackInfo.sampleEntryInfo?.channelCount === 2)
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

module.exports = {
  hasConsistentVoiceWavLayout,
  isSupportedVoiceWavFormat,
  readM4AInfo,
  readWavInfo,
  wavDurationMs,
};
