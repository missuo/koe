#include "audio.h"
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <vector>
#include <cmath>

// ASR expects 16kHz mono Int16 LE, 200ms frames
static const UINT32 kTargetSampleRate = 16000;
static const UINT32 kFrameSamples = 3200;  // 200ms at 16kHz
static const UINT32 kFrameBytes = kFrameSamples * sizeof(int16_t);  // 6400

AudioCapture::AudioCapture() {
    m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

AudioCapture::~AudioCapture() {
    stop();
    if (m_stopEvent) CloseHandle(m_stopEvent);
}

void AudioCapture::start(AudioFrameCallback callback) {
    if (m_capturing) return;

    m_callback = callback;
    ResetEvent(m_stopEvent);
    m_capturing = true;

    m_thread = CreateThread(nullptr, 0, captureThread, this, 0, nullptr);
    if (!m_thread) {
        m_capturing = false;
        OutputDebugStringA("[Koe] Failed to create audio capture thread\n");
    }
}

void AudioCapture::stop() {
    if (!m_capturing) return;
    m_capturing = false;

    SetEvent(m_stopEvent);
    if (m_thread) {
        WaitForSingleObject(m_thread, 3000);
        CloseHandle(m_thread);
        m_thread = nullptr;
    }
    m_callback = nullptr;
}

DWORD WINAPI AudioCapture::captureThread(LPVOID param) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    auto* self = static_cast<AudioCapture*>(param);
    self->captureLoop();
    CoUninitialize();
    return 0;
}

void AudioCapture::captureLoop() {
    HRESULT hr;

    // Get default capture device
    IMMDeviceEnumerator* enumerator = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) {
        OutputDebugStringA("[Koe] Failed to create device enumerator\n");
        return;
    }

    IMMDevice* device = nullptr;
    if (!m_deviceId.empty()) {
        hr = enumerator->GetDevice(m_deviceId.c_str(), &device);
        if (FAILED(hr)) {
            OutputDebugStringA("[Koe] Selected device not found, falling back to default\n");
            hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
        }
    } else {
        hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    }
    enumerator->Release();
    if (FAILED(hr)) {
        OutputDebugStringA("[Koe] No capture device found\n");
        return;
    }

    // Initialize audio client
    IAudioClient* audioClient = nullptr;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&audioClient));
    device->Release();
    if (FAILED(hr)) {
        OutputDebugStringA("[Koe] Failed to activate audio client\n");
        return;
    }

    WAVEFORMATEX* deviceFormat = nullptr;
    hr = audioClient->GetMixFormat(&deviceFormat);
    if (FAILED(hr)) {
        audioClient->Release();
        OutputDebugStringA("[Koe] Failed to get mix format\n");
        return;
    }

    {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "[Koe] Device format: %dHz %dch %dbit\n",
                 deviceFormat->nSamplesPerSec, deviceFormat->nChannels,
                 deviceFormat->wBitsPerSample);
        OutputDebugStringA(buf);
    }

    // Use event-driven capture
    HANDLE captureEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    REFERENCE_TIME bufferDuration = 200 * 10000;  // 200ms in 100ns units
    hr = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                  bufferDuration, 0, deviceFormat, nullptr);
    if (FAILED(hr)) {
        CoTaskMemFree(deviceFormat);
        audioClient->Release();
        CloseHandle(captureEvent);
        OutputDebugStringA("[Koe] Failed to initialize audio client\n");
        return;
    }

    audioClient->SetEventHandle(captureEvent);

    IAudioCaptureClient* captureClient = nullptr;
    hr = audioClient->GetService(__uuidof(IAudioCaptureClient),
                                  reinterpret_cast<void**>(&captureClient));
    if (FAILED(hr)) {
        CoTaskMemFree(deviceFormat);
        audioClient->Release();
        CloseHandle(captureEvent);
        OutputDebugStringA("[Koe] Failed to get capture client\n");
        return;
    }

    // Capture parameters
    UINT32 deviceSampleRate = deviceFormat->nSamplesPerSec;
    UINT32 deviceChannels = deviceFormat->nChannels;
    UINT16 bitsPerSample = deviceFormat->wBitsPerSample;
    bool isFloat = false;

    if (deviceFormat->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        isFloat = true;
    } else if (deviceFormat->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(deviceFormat);
        if (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
            isFloat = true;
        }
    }

    CoTaskMemFree(deviceFormat);
    deviceFormat = nullptr;

    // Validate: we support float or 16-bit integer PCM
    if (!isFloat && bitsPerSample != 16) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "[Koe] Unsupported audio format: %d-bit integer PCM\n",
                 bitsPerSample);
        OutputDebugStringA(buf);
        captureClient->Release();
        audioClient->Release();
        CloseHandle(captureEvent);
        return;
    }

    // Start capturing
    hr = audioClient->Start();
    if (FAILED(hr)) {
        captureClient->Release();
        audioClient->Release();
        CloseHandle(captureEvent);
        OutputDebugStringA("[Koe] Failed to start audio capture\n");
        return;
    }

    OutputDebugStringA("[Koe] Audio capture started\n");

    // Accumulation buffer for 200ms frames
    std::vector<int16_t> accumBuffer;
    accumBuffer.reserve(kFrameSamples * 2);

    // Simple resampling state
    double resampleRatio = static_cast<double>(kTargetSampleRate) / deviceSampleRate;
    double resamplePos = 0.0;

    HANDLE waitHandles[2] = { m_stopEvent, captureEvent };

    while (m_capturing) {
        DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, 500);

        if (waitResult == WAIT_OBJECT_0) {
            // Stop event signaled
            break;
        }

        // Read available packets
        UINT32 packetLength = 0;
        while (SUCCEEDED(captureClient->GetNextPacketSize(&packetLength)) && packetLength > 0) {
            BYTE* data = nullptr;
            UINT32 numFrames = 0;
            DWORD flags = 0;

            hr = captureClient->GetBuffer(&data, &numFrames, &flags, nullptr, nullptr);
            if (FAILED(hr)) break;

            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data && numFrames > 0) {
                // Convert to mono float, then resample to 16kHz, then to int16
                for (UINT32 i = 0; i < numFrames; i++) {
                    // Get mono sample as float
                    float sample = 0.0f;
                    if (isFloat) {
                        float* floatData = reinterpret_cast<float*>(data);
                        // Average all channels to mono
                        for (UINT32 ch = 0; ch < deviceChannels; ch++) {
                            sample += floatData[i * deviceChannels + ch];
                        }
                        sample /= deviceChannels;
                    } else {
                        // 16-bit PCM
                        int16_t* pcmData = reinterpret_cast<int16_t*>(data);
                        for (UINT32 ch = 0; ch < deviceChannels; ch++) {
                            sample += pcmData[i * deviceChannels + ch] / 32768.0f;
                        }
                        sample /= deviceChannels;
                    }

                    // Simple linear resampling
                    resamplePos += resampleRatio;
                    while (resamplePos >= 1.0) {
                        resamplePos -= 1.0;

                        // Clamp and convert to int16
                        if (sample > 1.0f) sample = 1.0f;
                        if (sample < -1.0f) sample = -1.0f;
                        int16_t pcmSample = static_cast<int16_t>(sample * 32767.0f);
                        accumBuffer.push_back(pcmSample);

                        // Emit 200ms frames
                        if (accumBuffer.size() >= kFrameSamples) {
                            if (m_callback) {
                                LARGE_INTEGER counter;
                                QueryPerformanceCounter(&counter);
                                m_callback(reinterpret_cast<const uint8_t*>(accumBuffer.data()),
                                           kFrameBytes,
                                           static_cast<uint64_t>(counter.QuadPart));
                            }
                            accumBuffer.erase(accumBuffer.begin(),
                                              accumBuffer.begin() + kFrameSamples);
                        }
                    }
                }
            }

            captureClient->ReleaseBuffer(numFrames);
        }
    }

    // Flush remaining audio (prevents last words from being cut off)
    if (!accumBuffer.empty() && m_callback) {
        OutputDebugStringA("[Koe] Flushing remaining audio\n");
        LARGE_INTEGER counter;
        QueryPerformanceCounter(&counter);
        m_callback(reinterpret_cast<const uint8_t*>(accumBuffer.data()),
                   static_cast<uint32_t>(accumBuffer.size() * sizeof(int16_t)),
                   static_cast<uint64_t>(counter.QuadPart));
    }

    audioClient->Stop();
    captureClient->Release();
    audioClient->Release();
    CloseHandle(captureEvent);

    OutputDebugStringA("[Koe] Audio capture stopped\n");
}
