// Runs in the audio thread of a 16 kHz AudioContext (Chromium resamples the input): converts the mono input to 16-bit
// PCM and posts it about once a second, with an RMS level ten times a second for the meter.
class PcmRecorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Int16Array(sampleRate);
    this.length = 0;
    this.sum = 0;
    this.count = 0;
    this.stopped = false;
    this.port.onmessage = (event) => {
      if (event.data === "flush") {
        this.stopped = true;
        this.send();
        this.port.postMessage({ flushed: true });
      }
    };
  }

  send() {
    if (this.length === 0) return;
    const pcm = this.buffer.slice(0, this.length).buffer;
    this.length = 0;
    this.port.postMessage({ pcm }, [pcm]);
  }

  process(inputs) {
    if (this.stopped) return false;
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (let index = 0; index < channel.length; index++) {
        const sample = Math.max(-1, Math.min(1, channel[index]));
        this.buffer[this.length++] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
        this.sum += sample * sample;
        this.count++;
        if (this.length === this.buffer.length) this.send();
        if (this.count === sampleRate / 10) {
          this.port.postMessage({ level: Math.sqrt(this.sum / this.count) });
          this.sum = 0;
          this.count = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor("pcm-recorder", PcmRecorder);
