// 权限请求可能一直悬置；超时后迟到的流必须释放，不能继续录音。
export async function requestMicrophone(request: () => Promise<MediaStream>, timeoutMs = 15_000): Promise<MediaStream> {
  let expired = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const pending = request().then(stream => {
    if (expired) stream.getTracks().forEach(track => track.stop());
    return stream;
  });
  try {
    return await Promise.race([
      pending,
      new Promise<MediaStream>((_, reject) => {
        timer = setTimeout(() => {
          expired = true;
          reject(new Error('麦克风授权未完成，请允许访问或使用支持录音的浏览器'));
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// stop() 后仍会触发最后一次 dataavailable，绑定本次数组，避免被下一次录音清空。
export function collectRecordingChunks(recorder: Pick<MediaRecorder, 'addEventListener'>): Blob[] {
  const chunks: Blob[] = [];
  recorder.addEventListener('dataavailable', (event: BlobEvent) => {
    if (event.data.size > 0) chunks.push(event.data);
  });
  return chunks;
}
