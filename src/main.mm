#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include <juce_audio_utils/juce_audio_utils.h>
#include <juce_dsp/juce_dsp.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <unordered_set>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Color {
    double r;
    double g;
    double b;
    double a;
};

struct Vec2 {
    double x;
    double y;
};

enum class VisualStyle {
    Invaders,
    Tempest,
    Rez
};

enum class AudioEventType {
    Reset,
    NoteHit,
    WrongPress,
    Damage,
    BeatStep,
    ChainStep,
    StreakChord,
    GameOver
};

struct AudioEvent {
    AudioEventType type = AudioEventType::Reset;
    double freq = 0.0;
    int step = 0;
    VisualStyle style = VisualStyle::Invaders;
    VisualStyle altStyle = VisualStyle::Invaders;
    bool accent = false;
    bool final = false;
    int amount = 0;
    double morph = 0.0;
};

struct ScheduledAudioEvent {
    AudioEvent event;
    double fireTime = 0.0;
};

struct NoteChoice {
    std::string key;
    std::string note;
    std::string pitchClass;
    double freq;
    Color color;
};

struct LevelDefinition {
    std::string name;
    std::string displayName;
    VisualStyle style;
    double duration;
    double changeEvery;
    std::vector<std::vector<std::string>> scalePool;
};

struct Monster {
    int id;
    Vec2 pos;
    double speed;
    double size;
    std::string key;
    std::string note;
    std::string pitchClass;
    double freq;
    Color color;
    double wobbleAmp;
    double wobbleSpeed;
    double wobblePhase;
    VisualStyle style;
    double laneAngle;
    double angularVel;
    double spiralTightness;
    double formationOffset;
    double twistOffset;
};

struct Particle {
    Vec2 pos;
    Vec2 vel;
    double life;
    double maxLife;
    double size;
    Color color;
};

struct Pulse {
    Vec2 pos;
    double radius;
    double maxRadius;
    double life;
    double maxLife;
    Color color;
};

struct ChainStep {
    Vec2 pos;
    double freq;
    Color color;
};

struct GameState {
    int score = 0;
    int lives = 8;
    int wave = 1;
    int streak = 0;
    int misses = 0;
    int beatStep = 0;
    double spawnTimer = 0.0;
    double spawnInterval = 1.1;
    double elapsed = 0.0;
    std::vector<Monster> monsters;
    std::vector<Particle> particles;
    std::vector<Pulse> pulses;
    VisualStyle visualStyle = VisualStyle::Invaders;
    double levelFlash = 0.0;
    double formationPhase = 0.0;
    double tempestTwistPulse = 0.0;
    double beatTime = 0.0;
    double beatInterval = 60.0 / 128.0;
    double beatPulse = 0.0;
    std::string heldKey;
    std::vector<int> lockBuffer;
    std::vector<ChainStep> chainQueue;
    bool chaining = false;
    int chainLength = 0;
    int chainIndex = 0;
    double chainNextTime = 0.0;
    int chainSubdivision = 1;
    int maxLocks = 8;
};

Color makeColor(int r, int g, int b, double a = 1.0) {
    return Color{r / 255.0, g / 255.0, b / 255.0, a};
}

NSColor* toNSColor(const Color& c) {
    return [NSColor colorWithCalibratedRed:c.r green:c.g blue:c.b alpha:c.a];
}

Color withAlpha(Color c, double alpha) {
    c.a = alpha;
    return c;
}

const std::array<Color, 6> kRainbowPalette = {{
    makeColor(228, 3, 3),
    makeColor(255, 140, 0),
    makeColor(255, 237, 0),
    makeColor(0, 128, 38),
    makeColor(0, 77, 255),
    makeColor(117, 7, 135)
}};

Color rainbowColor(double t, double alpha = 1.0) {
    double wrapped = t - std::floor(t);
    double scaled = wrapped * static_cast<double>(kRainbowPalette.size());
    int indexA = static_cast<int>(std::floor(scaled)) % static_cast<int>(kRainbowPalette.size());
    int indexB = (indexA + 1) % static_cast<int>(kRainbowPalette.size());
    double m = scaled - std::floor(scaled);
    auto blend = [m](double a, double b) { return a + (b - a) * m; };
    return {
        blend(kRainbowPalette[static_cast<size_t>(indexA)].r, kRainbowPalette[static_cast<size_t>(indexB)].r),
        blend(kRainbowPalette[static_cast<size_t>(indexA)].g, kRainbowPalette[static_cast<size_t>(indexB)].g),
        blend(kRainbowPalette[static_cast<size_t>(indexA)].b, kRainbowPalette[static_cast<size_t>(indexB)].b),
        alpha
    };
}

double length(Vec2 v) {
    return std::sqrt(v.x * v.x + v.y * v.y);
}

Vec2 operator+(Vec2 a, Vec2 b) {
    return {a.x + b.x, a.y + b.y};
}

Vec2 operator-(Vec2 a, Vec2 b) {
    return {a.x - b.x, a.y - b.y};
}

Vec2 operator*(Vec2 a, double s) {
    return {a.x * s, a.y * s};
}

double wrapPhase(double phase) {
    phase -= std::floor(phase);
    return phase;
}

double semitoneRatio(int semitones) {
    return std::pow(2.0, semitones / 12.0);
}

const std::array<NoteChoice, 12> kChromaticNoteMap = {{
    {"A", "A4", "A", 440.0, makeColor(255, 92, 122)},
    {"B", "B4", "B", 493.88, makeColor(255, 159, 67)},
    {"C", "C5", "C", 523.25, makeColor(255, 209, 102)},
    {"D", "D5", "D", 587.33, makeColor(123, 223, 242)},
    {"E", "E5", "E", 659.25, makeColor(110, 231, 183)},
    {"F", "F5", "F", 698.46, makeColor(96, 165, 250)},
    {"G", "G5", "G", 783.99, makeColor(167, 139, 250)},
    {"1", "A#4", "A#", 466.16, makeColor(255, 122, 168)},
    {"2", "C#5", "C#", 554.37, makeColor(255, 229, 138)},
    {"3", "D#5", "D#", 622.25, makeColor(140, 231, 255)},
    {"4", "F#5", "F#", 739.99, makeColor(141, 184, 255)},
    {"5", "G#5", "G#", 830.61, makeColor(210, 155, 255)}
}};

const std::array<LevelDefinition, 3> kLevelDefinitions = {{
    {"Level 1", "C major", VisualStyle::Invaders, 27.0, 0.0, {{"C", "D", "E", "F", "G", "A", "B"}}},
    {"Level 2", "Whole-tone shifts", VisualStyle::Tempest, 27.0, 9.0, {{"C", "D", "E", "F#", "G#", "A#"}, {"C#", "D#", "F", "G", "A", "B"}}},
    {"Level 3", "Chromatic modal drift", VisualStyle::Rez, 1.0e9, 10.5, {{"C", "D", "E", "F", "G", "A", "B"}, {"C", "D", "D#", "F", "G", "A", "A#"}, {"C#", "D#", "F", "F#", "G#", "A#", "C"}, {"D", "E", "F", "G", "A", "A#", "C#"}, {"E", "F#", "G", "A", "B", "C", "D#"}}}
}};

struct ScaleState {
    int levelIndex;
    std::string levelName;
    std::string displayName;
    VisualStyle style;
    std::vector<std::string> notes;
};

class AudioEngine : public juce::AudioIODeviceCallback {
public:
    AudioEngine() {
        juce::String error = deviceManager_.initialise(0, 2, nullptr, true);
        juce::ignoreUnused(error);
        deviceManager_.addAudioCallback(this);
    }

    ~AudioEngine() override {
        deviceManager_.removeAudioCallback(this);
    }

    void queueEvent(const AudioEvent& event) {
        std::lock_guard<std::mutex> lock(mutex_);
        pendingEvents_.push_back(event);
    }

    void audioDeviceAboutToStart(juce::AudioIODevice* device) override {
        sampleRate_ = device != nullptr ? device->getCurrentSampleRate() : 48000.0;
        if (sampleRate_ <= 0.0) sampleRate_ = 48000.0;
        delayLength_ = static_cast<size_t>(std::max(1.0, sampleRate_ * 0.42));
        delayLeft_.assign(delayLength_, 0.0f);
        delayRight_.assign(delayLength_, 0.0f);
        delayIndex_ = 0;
        std::lock_guard<std::mutex> lock(mutex_);
        voices_.clear();
        pendingEvents_.clear();
    }

    void audioDeviceStopped() override {
        std::lock_guard<std::mutex> lock(mutex_);
        voices_.clear();
    }

    void audioDeviceIOCallbackWithContext(const float* const* inputChannelData,
                                          int numInputChannels,
                                          float* const* outputChannelData,
                                          int numOutputChannels,
                                          int numSamples,
                                          const juce::AudioIODeviceCallbackContext& context) override {
        juce::ignoreUnused(inputChannelData, numInputChannels, context);
        if (numOutputChannels <= 0 || numSamples <= 0) return;

        juce::ScopedNoDenormals noDenormals;

        std::deque<AudioEvent> events;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            events.swap(pendingEvents_);
        }

        while (!events.empty()) {
            handleEvent(events.front());
            events.pop_front();
        }

        for (int channel = 0; channel < numOutputChannels; ++channel) {
            juce::FloatVectorOperations::clear(outputChannelData[channel], numSamples);
        }

        for (int sample = 0; sample < numSamples; ++sample) {
            float left = 0.0f;
            float right = 0.0f;
            float dryLeft = 0.0f;
            float dryRight = 0.0f;
            for (auto& voice : voices_) {
                float voiceLeft = 0.0f;
                float voiceRight = 0.0f;
                voice.render(sampleRate_, rng_, voiceLeft, voiceRight);
                if (voice.bypassDelay) {
                    dryLeft += voiceLeft;
                    dryRight += voiceRight;
                } else {
                    left += voiceLeft;
                    right += voiceRight;
                }
            }

            float delayedL = delayLeft_[delayIndex_];
            float delayedR = delayRight_[delayIndex_];

            float wetL = left + delayedL * 0.58f + delayedR * 0.14f;
            float wetR = right + delayedR * 0.58f + delayedL * 0.14f;

            delayLeft_[delayIndex_] = std::tanh(left + delayedR * 0.42f);
            delayRight_[delayIndex_] = std::tanh(right + delayedL * 0.42f);
            delayIndex_ = (delayIndex_ + 1) % delayLength_;

            wetL = std::tanh(wetL * 1.18f) * 0.42f + dryLeft * 0.82f;
            wetR = std::tanh(wetR * 1.18f) * 0.42f + dryRight * 0.82f;

            outputChannelData[0][sample] = juce::jlimit(-0.98f, 0.98f, wetL);
            if (numOutputChannels > 1) outputChannelData[1][sample] = juce::jlimit(-0.98f, 0.98f, wetR);
            for (int channel = 2; channel < numOutputChannels; ++channel) outputChannelData[channel][sample] = outputChannelData[0][sample];
        }

        voices_.erase(std::remove_if(voices_.begin(), voices_.end(), [](const auto& voice) {
            return voice.finished;
        }), voices_.end());
    }

private:
    struct Voice {
        enum class Wave {
            Sine,
            Triangle,
            Saw,
            Square,
            Noise,
            Pulse
        };

        Wave wave = Wave::Sine;
        double startFreq = 440.0;
        double endFreq = 440.0;
        double duration = 0.2;
        double attack = 0.005;
        double sustainLevel = 0.5;
        double gain = 0.18;
        double phaseA = 0.0;
        double phaseB = 0.0;
        double phaseSub = 0.0;
        double detune = 0.0;
        double subGain = 0.0;
        double noiseMix = 0.0;
        double lowpassHz = 22000.0;
        double highpassHz = 0.0;
        double lowpassState = 0.0;
        double highpassState = 0.0;
        double highpassLow = 0.0;
        double bandpassState = 0.0;
        double bandpassLow = 0.0;
        double bandpassHz = 0.0;
        double pulseWidth = 0.28;
        double pan = 0.0;
        bool bypassDelay = false;
        double age = 0.0;
        bool finished = false;

        static double osc(Wave waveType, double phase) {
            switch (waveType) {
                case Wave::Sine: return std::sin(phase * 2.0 * kPi);
                case Wave::Triangle: return 1.0 - 4.0 * std::fabs(phase - 0.5);
                case Wave::Saw: return phase * 2.0 - 1.0;
                case Wave::Square: return phase < 0.5 ? 1.0 : -1.0;
                case Wave::Pulse: return phase < 0.28 ? 1.0 : -1.0;
                case Wave::Noise: return 0.0;
            }
            return 0.0;
        }

        float render(double sampleRate, std::mt19937& rng, float& leftOut, float& rightOut) {
            if (finished || sampleRate <= 0.0) return 0.0f;

            double t = duration > 0.0 ? juce::jlimit(0.0, 1.0, age / duration) : 1.0;
            double freq = juce::jmap(t, startFreq, endFreq);
            double delta = freq / sampleRate;

            phaseA = wrapPhase(phaseA + delta);
            phaseB = wrapPhase(phaseB + delta * (1.0 + detune));
            phaseSub = wrapPhase(phaseSub + delta * 0.5);

            std::uniform_real_distribution<double> random(-1.0, 1.0);

            double raw = wave == Wave::Pulse ? (phaseA < pulseWidth ? 1.0 : -1.0) : osc(wave, phaseA);
            if (wave != Wave::Noise && detune != 0.0) raw += osc(wave, phaseB) * 0.65;
            if (subGain > 0.0) raw += osc(Wave::Sine, phaseSub) * subGain;
            if (wave == Wave::Noise || noiseMix > 0.0) raw += random(rng) * std::max(1.0, noiseMix);

            double attackEnd = std::max(attack, 0.001);
            double releaseStart = std::max(attackEnd, duration * 0.2);
            double env = 0.0;
            if (age < attackEnd) env = age / attackEnd;
            else if (age < releaseStart) env = juce::jmap(age, attackEnd, releaseStart, 1.0, sustainLevel);
            else env = juce::jmap(age, releaseStart, duration, sustainLevel, 0.0);

            auto coeffFor = [sampleRate](double hz) {
                double clamped = juce::jlimit(20.0, sampleRate * 0.45, hz);
                return 1.0 - std::exp(-2.0 * kPi * clamped / sampleRate);
            };

            if (lowpassHz < sampleRate * 0.45) {
                double coeff = coeffFor(lowpassHz);
                lowpassState += coeff * (raw - lowpassState);
                raw = lowpassState;
            }

            if (highpassHz > 20.0) {
                double coeff = coeffFor(highpassHz);
                highpassLow += coeff * (raw - highpassLow);
                highpassState = raw - highpassLow;
                raw = highpassState;
            }

            if (bandpassHz > 20.0) {
                double coeff = coeffFor(bandpassHz);
                bandpassLow += coeff * (raw - bandpassLow);
                bandpassState = raw - bandpassLow;
                raw = bandpassState;
            }

            raw = std::tanh(raw * 1.7);

            age += 1.0 / sampleRate;
            if (age >= duration) finished = true;

            float sample = static_cast<float>(raw * env * gain);
            float leftGain = std::sqrt(0.5f * static_cast<float>(1.0 - pan));
            float rightGain = std::sqrt(0.5f * static_cast<float>(1.0 + pan));
            leftOut += sample * leftGain;
            rightOut += sample * rightGain;
            return sample;
        }
    };

    void addVoice(const Voice& voice) {
        voices_.push_back(voice);
    }

    void addNoteVoice(double freq, double duration, Voice::Wave wave, double gain, double detune, double subGain, double lowpassHz, double pan = 0.0, double pulseWidth = 0.28) {
        Voice voice;
        voice.wave = wave;
        voice.startFreq = freq;
        voice.endFreq = freq;
        voice.duration = duration;
        voice.attack = 0.005;
        voice.sustainLevel = 0.35;
        voice.gain = gain;
        voice.detune = detune;
        voice.subGain = subGain;
        voice.lowpassHz = lowpassHz;
        voice.pan = pan;
        voice.pulseWidth = pulseWidth;
        addVoice(voice);
    }

    void addRezLead(double freq, double duration, double gain, bool accent, bool final, double pan = 0.0) {
        Voice lead;
        lead.wave = Voice::Wave::Pulse;
        lead.startFreq = accent ? freq * 1.01 : freq;
        lead.endFreq = final ? freq * 0.995 : freq * 1.002;
        lead.duration = duration;
        lead.attack = 0.003;
        lead.sustainLevel = final ? 0.52 : 0.4;
        lead.gain = gain;
        lead.detune = accent ? 0.004 : 0.0025;
        lead.subGain = final ? 0.14 : 0.08;
        lead.lowpassHz = accent ? 4200.0 : 3000.0;
        lead.highpassHz = 180.0;
        lead.pulseWidth = accent ? 0.18 : 0.24;
        lead.pan = pan;
        addVoice(lead);

        Voice shimmer = lead;
        shimmer.wave = Voice::Wave::Triangle;
        shimmer.startFreq = freq * 2.0;
        shimmer.endFreq = final ? freq * 2.02 : freq * 2.0;
        shimmer.duration = duration * 0.8;
        shimmer.attack = 0.002;
        shimmer.sustainLevel = 0.2;
        shimmer.gain = gain * (final ? 0.26 : 0.16);
        shimmer.detune = 0.0015;
        shimmer.subGain = 0.0;
        shimmer.lowpassHz = 5600.0;
        shimmer.highpassHz = 900.0;
        shimmer.pan = -pan * 0.65;
        addVoice(shimmer);
    }

    void addSupportLead(double freq, double duration, double gain, double pan, bool airy) {
        Voice support;
        support.wave = airy ? Voice::Wave::Triangle : Voice::Wave::Pulse;
        support.startFreq = freq;
        support.endFreq = freq * (airy ? 1.004 : 0.998);
        support.duration = duration;
        support.attack = airy ? 0.01 : 0.004;
        support.sustainLevel = airy ? 0.46 : 0.28;
        support.gain = gain;
        support.detune = airy ? 0.0015 : 0.002;
        support.subGain = airy ? 0.0 : 0.08;
        support.lowpassHz = airy ? 6200.0 : 2600.0;
        support.highpassHz = airy ? 680.0 : 140.0;
        support.pulseWidth = 0.22;
        support.pan = pan;
        addVoice(support);
    }

    void addKick(double gain) {
        Voice voice;
        voice.wave = Voice::Wave::Sine;
        voice.startFreq = 148.0;
        voice.endFreq = 43.0;
        voice.duration = 0.19;
        voice.attack = 0.002;
        voice.sustainLevel = 0.38;
        voice.gain = gain * 0.92;
        voice.lowpassHz = 280.0;
        addVoice(voice);

        Voice click = voice;
        click.wave = Voice::Wave::Noise;
        click.startFreq = 1.0;
        click.endFreq = 1.0;
        click.duration = 0.016;
        click.gain = gain * 0.085;
        click.lowpassHz = 9800.0;
        click.highpassHz = 2400.0;
        click.sustainLevel = 0.08;
        addVoice(click);
    }

    void addSnare(double gain) {
        Voice crack;
        crack.wave = Voice::Wave::Noise;
        crack.startFreq = 1.0;
        crack.endFreq = 1.0;
        crack.duration = 0.03;
        crack.attack = 0.0005;
        crack.sustainLevel = 0.02;
        crack.gain = gain * 0.22;
        crack.lowpassHz = 14000.0;
        crack.highpassHz = 3200.0;
        crack.pan = -0.04;
        crack.bypassDelay = true;
        addVoice(crack);

        Voice noise;
        noise.wave = Voice::Wave::Noise;
        noise.startFreq = 1.0;
        noise.endFreq = 1.0;
        noise.duration = 0.1;
        noise.attack = 0.0008;
        noise.sustainLevel = 0.14;
        noise.gain = gain * 0.24;
        noise.lowpassHz = 12000.0;
        noise.highpassHz = 2600.0;
        noise.bandpassHz = 1700.0;
        noise.pan = -0.12;
        noise.bypassDelay = true;
        addVoice(noise);

        Voice body;
        body.wave = Voice::Wave::Pulse;
        body.startFreq = 330.0;
        body.endFreq = 210.0;
        body.duration = 0.065;
        body.attack = 0.0012;
        body.sustainLevel = 0.08;
        body.gain = gain * 0.15;
        body.lowpassHz = 2800.0;
        body.highpassHz = 650.0;
        body.pulseWidth = 0.14;
        body.pan = 0.05;
        body.bypassDelay = true;
        addVoice(body);

        Voice thwack = body;
        thwack.wave = Voice::Wave::Triangle;
        thwack.startFreq = 520.0;
        thwack.endFreq = 240.0;
        thwack.duration = 0.038;
        thwack.attack = 0.0008;
        thwack.sustainLevel = 0.04;
        thwack.gain = gain * 0.11;
        thwack.lowpassHz = 4200.0;
        thwack.highpassHz = 1100.0;
        thwack.pan = 0.0;
        thwack.bypassDelay = true;
        addVoice(thwack);
    }

    void addHat(double gain, bool bright) {
        Voice hat;
        hat.wave = Voice::Wave::Noise;
        hat.startFreq = 1.0;
        hat.endFreq = 1.0;
        hat.duration = bright ? 0.028 : 0.018;
        hat.attack = 0.001;
        hat.sustainLevel = 0.04;
        hat.gain = gain * (bright ? 0.085 : 0.055);
        hat.lowpassHz = 16000.0;
        hat.highpassHz = bright ? 7600.0 : 9800.0;
        hat.pan = bright ? -0.18 : 0.22;
        addVoice(hat);
    }

    void addBassPulse(double freq, double gain) {
        Voice bass;
        bass.wave = Voice::Wave::Pulse;
        bass.startFreq = freq;
        bass.endFreq = freq * 0.992;
        bass.duration = 0.22;
        bass.attack = 0.003;
        bass.sustainLevel = 0.22;
        bass.gain = gain * 0.17;
        bass.detune = 0.0018;
        bass.subGain = 0.6;
        bass.lowpassHz = 240.0;
        bass.highpassHz = 32.0;
        bass.pulseWidth = 0.2;
        addVoice(bass);

        Voice transient = bass;
        transient.wave = Voice::Wave::Triangle;
        transient.startFreq = freq * 2.0;
        transient.endFreq = freq * 1.4;
        transient.duration = 0.07;
        transient.gain = gain * 0.045;
        transient.subGain = 0.0;
        transient.lowpassHz = 1300.0;
        transient.highpassHz = 240.0;
        addVoice(transient);
    }

    void addErrorTone() {
        addRezLead(185.0, 0.11, 0.11, false, false, -0.2);
        Voice error = voices_.back();
        voices_.pop_back();
        error.startFreq = 190.0;
        error.endFreq = 110.0;
        error.lowpassHz = 1100.0;
        error.highpassHz = 260.0;
        error.gain = 0.12;
        addVoice(error);
    }

    void addDamageTone() {
        Voice crack;
        crack.wave = Voice::Wave::Noise;
        crack.duration = 0.09;
        crack.attack = 0.001;
        crack.sustainLevel = 0.08;
        crack.gain = 0.12;
        crack.lowpassHz = 8000.0;
        crack.highpassHz = 1800.0;
        addVoice(crack);

        Voice thud;
        thud.wave = Voice::Wave::Pulse;
        thud.startFreq = 120.0;
        thud.endFreq = 60.0;
        thud.duration = 0.11;
        thud.attack = 0.002;
        thud.sustainLevel = 0.18;
        thud.gain = 0.08;
        thud.lowpassHz = 480.0;
        thud.highpassHz = 90.0;
        thud.pulseWidth = 0.24;
        addVoice(thud);
    }

    void addStyleChord(double rootFreq, int amount, VisualStyle style, double gain) {
        if (style == VisualStyle::Invaders) {
            addRezLead(rootFreq, 0.22 + amount * 0.006, gain * 0.14, true, false, 0.0);
            if (amount >= 10) addSupportLead(rootFreq * 2.0, 0.18, gain * 0.04, -0.08, false);
            return;
        }

        if (style == VisualStyle::Tempest) {
            std::vector<int> intervals{0, 7, 12, 16};
            for (size_t i = 0; i < intervals.size(); ++i) {
                double freq = rootFreq * semitoneRatio(intervals[i]);
                addRezLead(freq, 0.34 + amount * 0.01, gain * (i == 0 ? 0.18 : 0.12), i == 0, false, static_cast<double>(i) * 0.15 - 0.22);
            }
            addSupportLead(rootFreq * 2.0, 0.22, gain * 0.08, 0.26, true);
            return;
        }

        std::vector<int> intervals{0, 7, 12, 14, 19};
        if (amount >= 10) intervals.push_back(24);
        if (amount >= 20) intervals.push_back(28);

        for (size_t i = 0; i < intervals.size(); ++i) {
            double freq = rootFreq * semitoneRatio(intervals[i]);
            addRezLead(freq, 0.48 + amount * 0.014, gain * (i == 0 ? 0.24 : 0.16), i == 0 || i == 3, amount >= 20, static_cast<double>(i) * 0.12 - 0.3);
        }
        addSupportLead(rootFreq * 2.0, 0.4, gain * 0.14, -0.3, true);
        addSupportLead(rootFreq * 3.0, 0.32, gain * 0.08, 0.32, true);
    }

    void addKillMelody(double freq, VisualStyle style, bool accent, bool final, int amount, double morph) {
        double nextWeight = juce::jlimit(0.0, 1.0, morph);
        double panBias = accent ? 0.12 : -0.08;

        if (style == VisualStyle::Invaders) {
            addRezLead(freq, accent ? 0.24 : 0.16, accent ? 0.15 : 0.1, accent, final, panBias);
            addSupportLead(freq * semitoneRatio(accent ? 12 : 7), accent ? 0.18 : 0.12, accent ? 0.05 : 0.03, -panBias * 0.8, false);
            if (accent) addSupportLead(freq * 2.0, 0.14, 0.03 + nextWeight * 0.015, 0.16, true);
            return;
        }

        if (style == VisualStyle::Tempest) {
            addRezLead(freq, final ? 0.42 : (accent ? 0.3 : 0.22), final ? 0.2 : (accent ? 0.16 : 0.12), accent, final, panBias);
            addSupportLead(freq * semitoneRatio(7), 0.2, 0.055 + nextWeight * 0.01, -0.2, true);
            addSupportLead(freq * 2.0, accent ? 0.24 : 0.16, accent ? 0.07 : 0.045, 0.22, true);
            if (final || amount >= 4) addRezLead(freq * semitoneRatio(12), 0.18, 0.065, false, false, -0.24);
            return;
        }

        addRezLead(freq, final ? 0.62 : (accent ? 0.42 : 0.28), final ? 0.24 : (accent ? 0.18 : 0.14), accent, final, panBias);
        addSupportLead(freq * semitoneRatio(7), 0.28, 0.075 + nextWeight * 0.015, -0.24, true);
        addSupportLead(freq * 2.0, accent ? 0.34 : 0.22, accent ? 0.09 : 0.06, 0.24, true);
        if (accent || final) addRezLead(freq * semitoneRatio(12), 0.22, 0.08, false, false, -0.28);
        if (amount >= 6 || final) addRezLead(freq * semitoneRatio(19), 0.18, 0.06, false, false, 0.3);
    }

    void renderBeatLayer(VisualStyle style, int step, double weight) {
        if (weight <= 0.001) return;

        if (style == VisualStyle::Invaders) {
            double intensity = 0.82 * weight;
            if (step == 0 || step == 4) addKick(0.88 * intensity);
            if (step == 4) addBassPulse(49.0, 0.74 * weight);
            if (step == 2 || step == 6) addHat(0.26 * weight, false);
            return;
        }

        if (style == VisualStyle::Tempest) {
            double intensity = 1.0 * weight;
            if (step == 0 || step == 4) addKick(1.0 * intensity);
            if (step == 2 || step == 6) addSnare(0.95 * intensity);
            addHat((step % 2 == 0 ? 0.82 : 0.5) * intensity, true);
            if (step == 1 || step == 3 || step == 5 || step == 7) addHat(0.24 * intensity, false);
            if (step == 0 || step == 4) addBassPulse(61.74, intensity);
            return;
        }

        double intensity = 1.18 * weight;
        if (step == 0 || step == 4) addKick(1.08 * intensity);
        if (step == 2 || step == 6) addSnare(0.94 * intensity);
        addHat((step % 2 == 0 ? 0.92 : 0.58) * intensity, true);
        if (step == 1 || step == 3 || step == 5 || step == 7) addHat(0.34 * intensity, false);
        if (step == 3 || step == 7) addHat(0.3 * intensity, true);
        if (step == 0 || step == 4) addBassPulse(55.0, intensity);
    }

    void handleBeatStep(const AudioEvent& event) {
        double nextWeight = juce::jlimit(0.0, 1.0, event.morph);
        double currentWeight = 1.0 - nextWeight;
        renderBeatLayer(event.style, event.step, currentWeight);
        if (event.altStyle != event.style) renderBeatLayer(event.altStyle, event.step, nextWeight);
    }

    void handleEvent(const AudioEvent& event) {
        switch (event.type) {
            case AudioEventType::Reset:
                voices_.clear();
                delayLeft_.assign(delayLength_, 0.0f);
                delayRight_.assign(delayLength_, 0.0f);
                delayIndex_ = 0;
                break;
            case AudioEventType::NoteHit:
                addKillMelody(event.freq, event.style, event.accent, false, std::max(1, event.amount), event.morph);
                break;
            case AudioEventType::WrongPress:
                addErrorTone();
                break;
            case AudioEventType::Damage:
                addDamageTone();
                break;
            case AudioEventType::BeatStep:
                handleBeatStep(event);
                break;
            case AudioEventType::ChainStep:
                addKillMelody(event.freq, event.style, event.accent, event.final, event.amount, event.morph);
                if (event.final && event.amount >= 4) {
                    VisualStyle chordStyle = event.morph >= 0.5 ? event.altStyle : event.style;
                    addStyleChord(event.freq, event.amount >= 7 ? 20 : 10, chordStyle, 0.65);
                }
                break;
            case AudioEventType::StreakChord:
                addStyleChord(event.freq, event.amount, event.morph >= 0.5 ? event.altStyle : event.style, 1.0);
                break;
            case AudioEventType::GameOver:
                addDamageTone();
                addNoteVoice(110.0, 0.7, Voice::Wave::Saw, 0.12, 0.001, 0.25, 900.0);
                break;
        }
    }

    juce::AudioDeviceManager deviceManager_;
    std::mutex mutex_;
    std::deque<AudioEvent> pendingEvents_;
    std::vector<Voice> voices_;
    std::mt19937 rng_{std::random_device{}()};
    double sampleRate_ = 48000.0;
    size_t delayLength_ = 48000;
    size_t delayIndex_ = 0;
    std::vector<float> delayLeft_ = std::vector<float>(delayLength_, 0.0f);
    std::vector<float> delayRight_ = std::vector<float>(delayLength_, 0.0f);
};

class Game {
public:
    struct TransitionState {
        VisualStyle fromStyle;
        VisualStyle toStyle;
        double mix;
    };

    Game()
    : rng_(std::random_device{}()) {
        reset();
    }

    void setAudioCallback(std::function<void(const AudioEvent&)> callback) {
        audioCallback_ = std::move(callback);
    }

    void setViewport(double width, double height) {
        width_ = width;
        height_ = height;
        center_ = {width * 0.5, height * 0.5};
    }

    void start() {
        reset();
        running_ = true;
        showStart_ = false;
        showGameOver_ = false;
        emit({AudioEventType::Reset});
    }

    void reset() {
        state_ = GameState{};
        running_ = false;
        showStart_ = true;
        showGameOver_ = false;
        nextMonsterId_ = 1;
        clockTime_ = 0.0;
        scheduledAudioEvents_.clear();
    }

    void update(double dt) {
        clockTime_ += dt;
        processScheduledAudioEvents();
        if (!running_) return;

        VisualStyle previousStyle = state_.visualStyle;

        state_.beatTime += dt;
        while (state_.beatTime >= state_.beatInterval) {
            state_.beatTime -= state_.beatInterval;
            state_.beatPulse = 1.0;
            TransitionState transition = transitionStateForElapsed(state_.elapsed);
            emit({AudioEventType::BeatStep, 0.0, state_.beatStep, transition.fromStyle, transition.toStyle, false, false, 0, transition.mix});
            if (state_.visualStyle == VisualStyle::Tempest) state_.tempestTwistPulse = 1.0;
            state_.beatStep = (state_.beatStep + 1) % 8;
        }

        state_.beatPulse *= 0.9;
        state_.tempestTwistPulse *= 0.86;
        state_.elapsed += dt;
        state_.wave = 1 + static_cast<int>(state_.elapsed / 18.0);
        state_.spawnInterval = std::max(0.24, 1.1 - state_.wave * 0.06);
        state_.formationPhase += dt * 1.7;

        ScaleState scaleState = currentScale();
        state_.visualStyle = scaleState.style;
        if (previousStyle != state_.visualStyle) {
            state_.levelFlash = 1.0;
        }
        state_.levelFlash = std::max(0.0, state_.levelFlash - dt * 1.8);

        state_.spawnTimer += dt;
        while (state_.spawnTimer >= state_.spawnInterval) {
            state_.spawnTimer -= state_.spawnInterval;
            spawnMonster();
            if (randf() < std::min(0.42, state_.wave * 0.045)) spawnMonster();
        }

        updateMonsters(dt);
        updateLocks();
        updateChains();
        updateParticles(dt);
        updatePulses(dt);
    }

    void keyDown(const std::string& key) {
        std::string upper = normalizeKey(key);
        if (upper.empty()) return;

        if (!running_) {
            if (upper == "ENTER" || upper == "R" || upper == "SPACE") start();
            return;
        }

        if (state_.visualStyle == VisualStyle::Rez) {
            if (state_.heldKey != upper) {
                state_.heldKey = upper;
                state_.lockBuffer.clear();
            }
            return;
        }

        std::vector<std::pair<double, int>> matches;
        for (size_t i = 0; i < state_.monsters.size(); ++i) {
            if (state_.monsters[i].key == upper) {
                matches.push_back({distanceToCenter(state_.monsters[i].pos), static_cast<int>(i)});
            }
        }

        if (matches.empty()) {
            wrongPress();
            return;
        }

        std::sort(matches.begin(), matches.end(), [](const auto& a, const auto& b) {
            return a.first < b.first;
        });
        killMonster(matches.front().second);
    }

    void keyUp(const std::string& key) {
        std::string upper = normalizeKey(key);
        if (!running_ || state_.visualStyle != VisualStyle::Rez) return;
        if (state_.heldKey != upper) return;

        std::vector<int> indices;
        for (int id : state_.lockBuffer) {
            auto it = std::find_if(state_.monsters.begin(), state_.monsters.end(), [&](const Monster& monster) {
                return monster.id == id;
            });
            if (it != state_.monsters.end()) {
                indices.push_back(static_cast<int>(std::distance(state_.monsters.begin(), it)));
            }
        }

        if (indices.empty()) wrongPress();
        else killMonsters(indices);

        state_.heldKey.clear();
        state_.lockBuffer.clear();
    }

    void mouseDown() {
        if (!running_) start();
    }

    bool running() const { return running_; }
    bool showStart() const { return showStart_; }
    bool showGameOver() const { return showGameOver_; }
    int score() const { return state_.score; }
    int lives() const { return state_.lives; }
    Vec2 center() const { return center_; }
    const GameState& state() const { return state_; }
    ScaleState scaleState() const { return currentScale(); }
    TransitionState visualTransition() const { return transitionStateForElapsed(state_.elapsed); }

    double ringRadius() const { return std::min(width_, height_) * 0.13; }
    double outerSpawnRadius() const { return std::max(width_, height_) * 0.62; }

    std::vector<int> currentTargets() const {
        if (state_.visualStyle != VisualStyle::Rez) return {};
        std::vector<int> targets = state_.lockBuffer;
        if (!targets.empty()) return targets;

        std::vector<std::pair<double, int>> byDistance;
        for (const auto& monster : state_.monsters) {
            byDistance.push_back({distanceToCenter(monster.pos), monster.id});
        }
        std::sort(byDistance.begin(), byDistance.end(), [](const auto& a, const auto& b) { return a.first < b.first; });

        std::vector<int> result;
        for (size_t i = 0; i < byDistance.size() && i < static_cast<size_t>(state_.maxLocks); ++i) result.push_back(byDistance[i].second);
        return result;
    }

private:
    void emit(const AudioEvent& event) {
        if (audioCallback_) audioCallback_(event);
    }

    void scheduleAudioEvent(const AudioEvent& event, double fireTime) {
        ScheduledAudioEvent scheduled{event, fireTime};
        auto it = std::upper_bound(scheduledAudioEvents_.begin(), scheduledAudioEvents_.end(), scheduled.fireTime,
                                   [](double time, const ScheduledAudioEvent& item) { return time < item.fireTime; });
        scheduledAudioEvents_.insert(it, scheduled);
    }

    void processScheduledAudioEvents() {
        while (!scheduledAudioEvents_.empty() && scheduledAudioEvents_.front().fireTime <= clockTime_) {
            emit(scheduledAudioEvents_.front().event);
            scheduledAudioEvents_.pop_front();
        }
    }

    void emitQuantizedKillMelody(const AudioEvent& event) {
        double grid = std::max(0.001, state_.beatInterval * 0.5);
        double quantizedTime = std::ceil(clockTime_ / grid) * grid;
        if (quantizedTime - clockTime_ < 0.03) {
            emit(event);
            return;
        }
        scheduleAudioEvent(event, quantizedTime);
    }

    ScaleState currentScale() const {
        return currentScaleForElapsed(state_.elapsed);
    }

    ScaleState currentScaleForElapsed(double elapsed) const {
        if (elapsed < kLevelDefinitions[0].duration) return {0, kLevelDefinitions[0].name, kLevelDefinitions[0].displayName, kLevelDefinitions[0].style, kLevelDefinitions[0].scalePool[0]};

        double level2Start = kLevelDefinitions[0].duration;
        double level2End = kLevelDefinitions[0].duration + kLevelDefinitions[1].duration;
        if (elapsed < level2End) {
            const auto& level = kLevelDefinitions[1];
            int scaleIndex = static_cast<int>((elapsed - level2Start) / level.changeEvery) % static_cast<int>(level.scalePool.size());
            return {1, level.name, level.displayName, level.style, level.scalePool[static_cast<size_t>(scaleIndex)]};
        }

        const auto& level = kLevelDefinitions[2];
        double localTime = elapsed - level2End;
        int scaleIndex = static_cast<int>(localTime / level.changeEvery) % static_cast<int>(level.scalePool.size());
        return {2, level.name, level.displayName, level.style, level.scalePool[static_cast<size_t>(scaleIndex)]};
    }

    TransitionState transitionStateForElapsed(double elapsed) const {
        constexpr double kTransitionDuration = 5.25;
        constexpr double kHalfWindow = kTransitionDuration * 0.5;
        const double boundary1 = kLevelDefinitions[0].duration;
        const double boundary2 = kLevelDefinitions[0].duration + kLevelDefinitions[1].duration;

        if (elapsed >= boundary1 - kHalfWindow && elapsed <= boundary1 + kHalfWindow) {
            double mix = juce::jlimit(0.0, 1.0, (elapsed - (boundary1 - kHalfWindow)) / kTransitionDuration);
            mix = mix * mix * (3.0 - 2.0 * mix);
            return {VisualStyle::Invaders, VisualStyle::Tempest, mix};
        }

        if (elapsed >= boundary2 - kHalfWindow && elapsed <= boundary2 + kHalfWindow) {
            double mix = juce::jlimit(0.0, 1.0, (elapsed - (boundary2 - kHalfWindow)) / kTransitionDuration);
            mix = mix * mix * (3.0 - 2.0 * mix);
            return {VisualStyle::Tempest, VisualStyle::Rez, mix};
        }

        VisualStyle style = currentScaleForElapsed(elapsed).style;
        return {style, style, 0.0};
    }

    std::vector<NoteChoice> activeChoices() const {
        ScaleState scale = currentScale();
        std::vector<NoteChoice> result;
        for (const auto& item : kChromaticNoteMap) {
            if (std::find(scale.notes.begin(), scale.notes.end(), item.pitchClass) != scale.notes.end()) result.push_back(item);
        }
        return result;
    }

    double randf() {
        return std::uniform_real_distribution<double>(0.0, 1.0)(rng_);
    }

    int randi(int minInclusive, int maxInclusive) {
        return std::uniform_int_distribution<int>(minInclusive, maxInclusive)(rng_);
    }

    double distanceToCenter(Vec2 pos) const {
        return length(pos - center_);
    }

    static std::string normalizeKey(const std::string& input) {
        std::string key = input;
        for (char& c : key) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        if (key == "\r" || key == "\n") return "ENTER";
        return key;
    }

    void spawnMonster() {
        std::vector<NoteChoice> choices = activeChoices();
        if (choices.empty()) return;

        const auto& choice = choices[static_cast<size_t>(randi(0, static_cast<int>(choices.size()) - 1))];
        VisualStyle style = currentScale().style;

        Monster monster{};
        monster.id = nextMonsterId_++;
        monster.speed = (45.0 + state_.wave * 7.0 + randf() * (55.0 + state_.wave * 5.0)) * 0.9;
        monster.size = 11.0 + randf() * 10.0;
        monster.key = choice.key;
        monster.note = choice.note;
        monster.pitchClass = choice.pitchClass;
        monster.freq = choice.freq;
        monster.color = choice.color;
        monster.wobbleAmp = 8.0 + randf() * 14.0;
        monster.wobbleSpeed = 1.5 + randf() * 2.4;
        monster.wobblePhase = randf() * kPi * 2.0;
        monster.style = style;

        if (style == VisualStyle::Invaders) {
            int columns = 7;
            double spacing = std::min(width_ * 0.09, 90.0);
            double totalWidth = spacing * (columns - 1);
            int column = randi(0, columns - 1);
            monster.pos.x = center_.x - totalWidth * 0.5 + column * spacing;
            monster.pos.y = -40.0 - randf() * 120.0;
            monster.formationOffset = (column - (columns - 1) * 0.5) * spacing * 0.18;
        } else if (style == VisualStyle::Tempest) {
            int lanes = 16;
            int laneIndex = randi(0, lanes - 1);
            monster.laneAngle = (static_cast<double>(laneIndex) / lanes) * kPi * 2.0;
            double radius = outerSpawnRadius();
            monster.pos.x = center_.x + std::cos(monster.laneAngle) * radius;
            monster.pos.y = center_.y + std::sin(monster.laneAngle) * radius;
            monster.angularVel = (randf() * 2.0 - 1.0) * (0.8 + randf() * 1.2);
            monster.spiralTightness = 0.6 + randf() * 0.8;
        } else {
            double angle = randf() * kPi * 2.0;
            double radius = outerSpawnRadius();
            monster.laneAngle = angle;
            monster.pos.x = center_.x + std::cos(angle) * radius;
            monster.pos.y = center_.y + std::sin(angle) * radius;
        }

        state_.monsters.push_back(monster);
    }

    void updateMonsters(double dt) {
        for (int i = static_cast<int>(state_.monsters.size()) - 1; i >= 0; --i) {
            Monster& m = state_.monsters[static_cast<size_t>(i)];

            if (m.style == VisualStyle::Invaders) {
                double swing = std::sin(state_.formationPhase) * std::min(width_ * 0.12, 110.0);
                m.pos.x += (center_.x + swing + m.formationOffset - m.pos.x) * std::min(1.0, dt * 1.8);
                m.pos.y += m.speed * 0.62 * dt;
                if (m.pos.y >= center_.y - ringRadius()) damagePlayer(i);
                continue;
            }

            if (m.style == VisualStyle::Tempest) {
                double angle = m.laneAngle;
                double radius = distanceToCenter(m.pos);
                double proximity = 1.0 + (1.0 / std::max(0.2, radius / outerSpawnRadius()));
                double direction = m.angularVel >= 0.0 ? 1.0 : -1.0;
                double continuousTwist = 0.25 * m.spiralTightness * direction * dt;
                double targetOffset = (kPi / 36.0) * proximity * state_.tempestTwistPulse * direction;
                m.twistOffset += (targetOffset - m.twistOffset) * std::min(1.0, dt * 6.0);
                angle += continuousTwist + m.twistOffset * dt * 4.0;
                radius -= m.speed * dt;
                m.laneAngle = angle;
                m.pos.x = center_.x + std::cos(angle) * radius;
                m.pos.y = center_.y + std::sin(angle) * radius;
                if (radius <= ringRadius() + m.size * 0.6) damagePlayer(i);
                continue;
            }

            Vec2 toCenter = center_ - m.pos;
            double dist = std::max(0.0001, length(toCenter));
            Vec2 normal{toCenter.x / dist, toCenter.y / dist};
            Vec2 tangent{-normal.y, normal.x};
            double wobble = std::sin(state_.elapsed * m.wobbleSpeed + m.wobblePhase) * m.wobbleAmp;
            m.pos = m.pos + normal * (m.speed * dt) + tangent * (wobble * dt);
            if (distanceToCenter(m.pos) <= ringRadius() + m.size * 0.6) damagePlayer(i);
        }
    }

    void updateLocks() {
        if (state_.visualStyle != VisualStyle::Rez || state_.heldKey.empty()) {
            state_.lockBuffer.clear();
            return;
        }

        std::unordered_set<int> existing(state_.lockBuffer.begin(), state_.lockBuffer.end());
        std::vector<std::pair<double, int>> candidates;
        for (const auto& monster : state_.monsters) {
            if (monster.key == state_.heldKey && !existing.count(monster.id)) candidates.push_back({distanceToCenter(monster.pos), monster.id});
        }

        std::sort(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) { return a.first < b.first; });

        int allowed = std::max(0, state_.maxLocks - static_cast<int>(state_.lockBuffer.size()));
        for (int i = 0; i < allowed && i < static_cast<int>(candidates.size()); ++i) state_.lockBuffer.push_back(candidates[static_cast<size_t>(i)].second);

        state_.lockBuffer.erase(std::remove_if(state_.lockBuffer.begin(), state_.lockBuffer.end(), [&](int id) {
            return std::none_of(state_.monsters.begin(), state_.monsters.end(), [&](const Monster& monster) {
                return monster.id == id;
            });
        }), state_.lockBuffer.end());
    }

    void updateChains() {
        if (!state_.chaining) return;
        double interval = state_.beatInterval / std::max(1, state_.chainSubdivision);
        while (state_.chaining && clockTime_ >= state_.chainNextTime) {
            processChainStep();
            state_.chainNextTime += interval;
        }
    }

    void processChainStep() {
        if (state_.chainQueue.empty()) {
            state_.chaining = false;
            state_.chainLength = 0;
            state_.chainIndex = 0;
            return;
        }

        ChainStep step = state_.chainQueue.front();
        state_.chainQueue.erase(state_.chainQueue.begin());

        int pos = state_.chainIndex;
        bool isAccent = pos == 0 || pos % 4 == 0;
        bool isFinal = state_.chainQueue.empty();
        double octave = pos >= state_.chainLength / 2.0 ? 2.0 : 1.0;

        createBurst(step.pos, step.color);
        state_.pulses.push_back({step.pos, isAccent ? 18.0 : 10.0, isFinal ? 180.0 : (isAccent ? 135.0 : 90.0), isFinal ? 0.72 : 0.48, isFinal ? 0.72 : 0.48, step.color});
        state_.pulses.push_back({center_, isAccent ? 26.0 : 16.0, isFinal ? 220.0 : 130.0, isFinal ? 0.7 : 0.36, isFinal ? 0.7 : 0.36, step.color});
        state_.beatPulse = std::min(2.4, state_.beatPulse + (isFinal ? 1.0 : (isAccent ? 0.6 : 0.35)));

        TransitionState transition = transitionStateForElapsed(state_.elapsed);
        emit({AudioEventType::ChainStep, step.freq * octave, 0, transition.fromStyle, transition.toStyle, isAccent, isFinal, state_.chainLength, transition.mix});

        state_.chainIndex += 1;
        if (state_.chainQueue.empty()) {
            state_.chaining = false;
            state_.chainLength = 0;
            state_.chainIndex = 0;
        }
    }

    void updateParticles(double dt) {
        for (int i = static_cast<int>(state_.particles.size()) - 1; i >= 0; --i) {
            Particle& p = state_.particles[static_cast<size_t>(i)];
            p.life -= dt;
            p.pos = p.pos + p.vel * dt;
            p.vel = p.vel * 0.975;
            if (p.life <= 0.0) state_.particles.erase(state_.particles.begin() + i);
        }
    }

    void updatePulses(double dt) {
        for (int i = static_cast<int>(state_.pulses.size()) - 1; i >= 0; --i) {
            Pulse& p = state_.pulses[static_cast<size_t>(i)];
            p.life -= dt;
            double t = 1.0 - p.life / p.maxLife;
            p.radius = p.radius + (p.maxRadius - p.radius) * std::min(1.0, 7.0 * dt + t * 0.05);
            if (p.life <= 0.0) state_.pulses.erase(state_.pulses.begin() + i);
        }
    }

    bool isOnBeat() const {
        double window = 0.08;
        return state_.beatTime < window || state_.beatTime > state_.beatInterval - window;
    }

    void createBurst(Vec2 pos, Color color) {
        for (int i = 0; i < 14; ++i) {
            double angle = randf() * kPi * 2.0;
            double speed = 40.0 + randf() * 180.0;
            double life = 0.7 + randf() * 0.4;
            state_.particles.push_back({pos, {std::cos(angle) * speed, std::sin(angle) * speed}, life, life, 2.0 + randf() * 5.0, color});
        }
        state_.pulses.push_back({pos, 8.0, 64.0, 0.4, 0.4, color});
        if (state_.pulses.size() > 28) {
            auto extra = static_cast<std::ptrdiff_t>(state_.pulses.size() - 28);
            state_.pulses.erase(state_.pulses.begin(), state_.pulses.begin() + extra);
        }
    }

    void wrongPress() {
        state_.misses += 1;
        state_.streak = 0;
        emit({AudioEventType::WrongPress});
    }

    void damagePlayer(int index) {
        if (index < 0 || index >= static_cast<int>(state_.monsters.size())) return;
        createBurst(state_.monsters[static_cast<size_t>(index)].pos, makeColor(255, 255, 255));
        state_.monsters.erase(state_.monsters.begin() + index);
        state_.lives -= 1;
        state_.streak = 0;
        state_.pulses.push_back({center_, ringRadius(), ringRadius() + 42.0, 0.5, 0.5, makeColor(255, 255, 255)});
        emit({AudioEventType::Damage});
        if (state_.lives <= 0) {
            running_ = false;
            showGameOver_ = true;
            emit({AudioEventType::GameOver});
        }
    }

    void maybeEmitStreakChord() {
        if (!(state_.streak == 5 || state_.streak == 10 || state_.streak == 20)) return;
        std::vector<NoteChoice> active = activeChoices();
        if (active.empty()) return;
        std::sort(active.begin(), active.end(), [](const auto& a, const auto& b) { return a.freq < b.freq; });
        int rootIndex = static_cast<int>(static_cast<double>(active.size()) * 0.3);
        rootIndex = juce::jlimit(0, static_cast<int>(active.size()) - 1, rootIndex);
        TransitionState transition = transitionStateForElapsed(state_.elapsed);
        emit({AudioEventType::StreakChord, active[static_cast<size_t>(rootIndex)].freq, 0, transition.fromStyle, transition.toStyle, true, false, state_.streak, transition.mix});
    }

    void killMonster(int index) {
        if (index < 0 || index >= static_cast<int>(state_.monsters.size())) return;
        Monster monster = state_.monsters[static_cast<size_t>(index)];
        bool onBeat = isOnBeat();
        createBurst(monster.pos, monster.color);
        state_.monsters.erase(state_.monsters.begin() + index);
        int base = 100 + std::min(500, state_.streak * 10);
        state_.score += onBeat ? base : base / 2;
        TransitionState transition = transitionStateForElapsed(state_.elapsed);
        emitQuantizedKillMelody({AudioEventType::NoteHit, monster.freq, 0, transition.fromStyle, transition.toStyle, onBeat, false, std::max(1, state_.streak + 1), transition.mix});
        if (onBeat) {
            state_.streak += 1;
            maybeEmitStreakChord();
        }
    }

    void killMonsters(std::vector<int> indices) {
        std::vector<NoteChoice> scale = activeChoices();
        std::sort(scale.begin(), scale.end(), [](const auto& a, const auto& b) { return a.freq < b.freq; });
        if (scale.empty()) return;

        std::vector<Monster> targets;
        for (int index : indices) {
            if (index >= 0 && index < static_cast<int>(state_.monsters.size())) targets.push_back(state_.monsters[static_cast<size_t>(index)]);
        }

        std::sort(indices.begin(), indices.end(), std::greater<int>());
        for (int index : indices) {
            if (index >= 0 && index < static_cast<int>(state_.monsters.size())) state_.monsters.erase(state_.monsters.begin() + index);
        }

        state_.chainQueue.clear();
        for (size_t i = 0; i < targets.size(); ++i) {
            const auto& note = scale[i % scale.size()];
            state_.chainQueue.push_back({targets[i].pos, note.freq, note.color});
        }

        state_.chainLength = static_cast<int>(targets.size());
        state_.chainIndex = 0;
        state_.chaining = !state_.chainQueue.empty();
        state_.chainSubdivision = state_.chainLength >= 7 ? 4 : (state_.chainLength >= 4 ? 2 : 1);
        state_.chainNextTime = clockTime_;
        state_.score += (100 + std::min(500, state_.streak * 10)) * static_cast<int>(targets.size());
    }

    GameState state_;
    std::mt19937 rng_;
    std::function<void(const AudioEvent&)> audioCallback_;
    double width_ = 1280.0;
    double height_ = 720.0;
    Vec2 center_{640.0, 360.0};
    bool running_ = false;
    bool showStart_ = true;
    bool showGameOver_ = false;
    int nextMonsterId_ = 1;
    double clockTime_ = 0.0;
    std::deque<ScheduledAudioEvent> scheduledAudioEvents_;
};

void fillRect(NSRect rect, NSColor* color) {
    [color setFill];
    NSRectFill(rect);
}

void strokeCircle(CGContextRef ctx, Vec2 center, double radius, NSColor* color, double lineWidth) {
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, static_cast<CGFloat>(lineWidth));
    CGRect rect = CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0);
    CGContextStrokeEllipseInRect(ctx, rect);
}

void fillCircle(CGContextRef ctx, Vec2 center, double radius, NSColor* color) {
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGRect rect = CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0);
    CGContextFillEllipseInRect(ctx, rect);
}

void strokeText(NSString* text, NSPoint point, NSDictionary* attrs, NSColor* strokeColor, double dx, double dy) {
    NSMutableDictionary* outline = [attrs mutableCopy];
    outline[NSStrokeColorAttributeName] = strokeColor;
    outline[NSStrokeWidthAttributeName] = @(-4.0);
    [text drawAtPoint:NSMakePoint(point.x + dx, point.y + dy) withAttributes:outline];
}

void drawGlassLabel(NSRect rect, double radius, NSColor* fill, NSColor* stroke) {
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [fill setFill];
    [path fill];
    [stroke setStroke];
    [path setLineWidth:1.6];
    [path stroke];
}

double lerp(double a, double b, double t) {
    return a + (b - a) * t;
}

Vec2 polarPoint(Vec2 center, double radius, double angle) {
    return {center.x + std::cos(angle) * radius, center.y + std::sin(angle) * radius};
}

Color mixColor(Color a, Color b, double t) {
    return {
        lerp(a.r, b.r, t),
        lerp(a.g, b.g, t),
        lerp(a.b, b.b, t),
        lerp(a.a, b.a, t)
    };
}

void addPolygonPath(CGContextRef ctx, const std::vector<Vec2>& points) {
    if (points.empty()) return;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, points.front().x, points.front().y);
    for (size_t i = 1; i < points.size(); ++i) {
        CGContextAddLineToPoint(ctx, points[i].x, points[i].y);
    }
    CGContextClosePath(ctx);
}

void fillPolygon(CGContextRef ctx, const std::vector<Vec2>& points, NSColor* color) {
    addPolygonPath(ctx, points);
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextFillPath(ctx);
}

void strokePolygon(CGContextRef ctx, const std::vector<Vec2>& points, NSColor* color, double lineWidth) {
    addPolygonPath(ctx, points);
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, static_cast<CGFloat>(lineWidth));
    CGContextStrokePath(ctx);
}

void drawRadialGradient(CGContextRef ctx, Vec2 center, double radius, Color inner, Color outer) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray* colors = @[ (id) toNSColor(inner).CGColor, (id) toNSColor(outer).CGColor ];
    CGFloat locations[] = { 0.0, 1.0 };
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (CFArrayRef) colors, locations);
    CGContextDrawRadialGradient(ctx,
                                gradient,
                                CGPointMake(center.x, center.y), 0.0,
                                CGPointMake(center.x, center.y), radius,
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
}

void drawLinearGradient(CGContextRef ctx, Vec2 a, Vec2 b, Color start, Color end) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray* colors = @[ (id) toNSColor(start).CGColor, (id) toNSColor(end).CGColor ];
    CGFloat locations[] = { 0.0, 1.0 };
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (CFArrayRef) colors, locations);
    CGContextDrawLinearGradient(ctx,
                                gradient,
                                CGPointMake(a.x, a.y),
                                CGPointMake(b.x, b.y),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
}

CGSize optimizedSceneSizeForDrawableSize(CGSize drawableSize) {
    double width = std::max(1.0, drawableSize.width);
    double height = std::max(1.0, drawableSize.height);

    constexpr double kTargetPixels = 512.0 * 288.0;
    constexpr double kMinWidth = 480.0;
    constexpr double kMinHeight = 270.0;
    constexpr double kMaxScale = 0.45;

    double pixelCount = width * height;
    double scale = std::min(kMaxScale, std::sqrt(kTargetPixels / pixelCount));
    if (!std::isfinite(scale) || scale <= 0.0) scale = 0.35;

    double scaledWidth = std::max(kMinWidth, std::round(width * scale));
    double scaledHeight = std::max(kMinHeight, std::round(height * scale));

    return CGSizeMake(scaledWidth, scaledHeight);
}

static NSString* const kPostProcessShaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct PostFXUniforms {
    float2 resolution;
    float time;
    float bloomStrength;
    float aberration;
    float distortion;
    float beatPulse;
};

vertex VertexOut postFXVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 uv = positions[vertexID] * 0.5 + 0.5;

    VertexOut outVertex;
    outVertex.position = float4(positions[vertexID], 0.0, 1.0);
    outVertex.uv = uv;
    return outVertex;
}

float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float3 rainbowColor(float t) {
    float wrapped = fract(t);
    float scaled = wrapped * 6.0;
    int indexA = int(floor(scaled)) % 6;
    int indexB = (indexA + 1) % 6;
    float mixAmount = fract(scaled);
    float3 palette[6] = {
        float3(228.0/255.0, 3.0/255.0, 3.0/255.0),
        float3(1.0, 140.0/255.0, 0.0),
        float3(1.0, 237.0/255.0, 0.0),
        float3(0.0, 128.0/255.0, 38.0/255.0),
        float3(0.0, 77.0/255.0, 1.0),
        float3(117.0/255.0, 7.0/255.0, 135.0/255.0)
    };
    return mix(palette[indexA], palette[indexB], mixAmount);
}

float3 sampleAcrylic(texture2d<float> sourceTexture, sampler texSampler, float2 uv, float2 aberration) {
    float3 core = sourceTexture.sample(texSampler, uv).rgb;
    float3 split = float3(
        sourceTexture.sample(texSampler, clamp(uv + aberration, float2(0.0), float2(1.0))).r,
        core.g,
        sourceTexture.sample(texSampler, clamp(uv - aberration, float2(0.0), float2(1.0))).b
    );
    return mix(core, split, 0.56);
}

fragment float4 postFXFragment(VertexOut in [[stage_in]],
                               constant PostFXUniforms& u [[buffer(0)]],
                               texture2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;
    float2 centered = uv * 2.0 - 1.0;
    float radius = length(centered);
    float2 dir = radius > 0.0001 ? centered / radius : float2(0.0);

    float wave = sin((uv.y * 13.0 + u.time * 0.55) * 2.0) * 0.5 + sin((uv.x * 9.0 - u.time * 0.27) * 3.0) * 0.5;
    float swirl = sin(radius * 22.0 - u.time * 1.35) * 0.0016;
    float2 distortion = dir * radius * radius * u.distortion + float2(dir.y, -dir.x) * swirl + dir * wave * 0.0012;
    float2 distortedUV = clamp(uv + distortion, float2(0.0), float2(1.0));

    float2 texel = 1.0 / u.resolution;
    float2 aberration = dir * (u.aberration * (0.45 + radius * 1.15)) * texel;
    float3 color = sampleAcrylic(sourceTexture, texSampler, distortedUV, aberration);
    float pulse = clamp(u.beatPulse, 0.0, 1.8);

    float3 bloom = float3(0.0);
    const int sampleCount = 8;
    for (int i = 0; i < sampleCount; ++i) {
        float angle = 6.2831853 * (float(i) / float(sampleCount));
        float2 offsetDir = float2(cos(angle), sin(angle));
        for (int ring = 1; ring <= 3; ++ring) {
            float ringScale = float(ring) * (1.0 + radius * 2.7 + pulse * 1.45);
            float2 sampleUV = clamp(distortedUV + offsetDir * texel * ringScale, float2(0.0), float2(1.0));
            float3 sampleColor = sourceTexture.sample(texSampler, sampleUV).rgb;
            float bright = smoothstep(0.56, 1.22, luminance(sampleColor));
            bloom += sampleColor * bright * (0.044 / float(ring));
        }
    }

    float fresnel = pow(clamp(1.0 - max(0.0, dot(dir, float2(0.0, -1.0))), 0.0, 1.0), 2.2);
    float acrylicMask = smoothstep(0.0, 1.0, luminance(color) * 1.05 + (1.0 - radius) * 0.34);
    float3 candyTint = rainbowColor(uv.y * 0.6 + u.time * 0.06 + 0.08);
    float3 bodyTint = mix(float3(0.22, 0.10, 0.32), candyTint, 0.58 + acrylicMask * 0.28);

    float glossLine = pow(max(0.0, 1.0 - abs(centered.y + 0.18 + sin(uv.x * 7.0 + u.time * 0.8) * 0.06) * 4.5), 6.0);
    float sweep = pow(max(0.0, 1.0 - abs(dot(normalize(float2(0.82, -0.57)), centered) - 0.08) * 3.2), 7.5);
    float3 specular = candyTint * (glossLine * 0.24 + sweep * 0.14 + fresnel * 0.18);

    float3 refraction = sampleAcrylic(sourceTexture, texSampler,
                                      clamp(distortedUV - dir * texel * (1.6 + radius * 2.2), float2(0.0), float2(1.0)),
                                      aberration * 0.35);
    float3 transmitted = mix(color, refraction, 0.34) * mix(float3(1.0), bodyTint, 0.52);
    float bands = sin((distortedUV.y * 32.0 - distortedUV.x * 11.0) + u.time * 1.6) * 0.5 + 0.5;
    float spokes = sin(atan2(centered.y, centered.x) * 14.0 - u.time * 2.4 + radius * 19.0) * 0.5 + 0.5;
    float3 psychedelic = rainbowColor(bands * 0.45 + distortedUV.x * 0.3 + u.time * 0.08);
    psychedelic = mix(psychedelic, rainbowColor(spokes * 0.22 + 0.33 + u.time * 0.05), spokes * 0.45 + pulse * 0.08);
    psychedelic = mix(psychedelic, rainbowColor(bands * 0.18 + distortedUV.y * 0.4 + 0.66), bands * 0.26);

    float halo = smoothstep(0.98, 0.12, radius);
    float3 finalColor = transmitted + bloom * u.bloomStrength + specular + bloom * halo * 0.15;
    finalColor = mix(finalColor, finalColor * candyTint, 0.24);
    finalColor += psychedelic * (0.14 + pulse * 0.04) * halo;
    finalColor += bloom * psychedelic * 0.14;

    float vignette = smoothstep(1.28, 0.22, radius);
    finalColor *= (0.74 + 0.26 * vignette);
    finalColor = pow(max(finalColor, float3(0.0)), float3(0.88));

    return float4(finalColor, 1.0);
}
)METAL";

} // namespace

@interface GameView : MTKView <MTKViewDelegate>
- (void)drawMonsterLabelsInBounds:(NSRect)bounds;
- (void)drawHUDInBounds:(NSRect)bounds;
- (void)drawOverlayInBounds:(NSRect)bounds title:(NSString*)title subtitle:(NSString*)subtitle footer:(NSString*)footer;
- (NSPoint)distortedOverlayPointForScenePoint:(Vec2)scenePoint bounds:(NSRect)bounds;
- (BOOL)gameRunningForOverlay;
- (BOOL)showStartForOverlay;
- (BOOL)showGameOverForOverlay;
- (int)scoreForOverlay;
- (VisualStyle)visualStyleForOverlay;
@end

@class GameView;

@interface GameOverlayView : NSView
- (instancetype)initWithFrame:(NSRect)frame owner:(GameView*)owner;
@end

@implementation GameView {
    Game _game;
    std::unique_ptr<AudioEngine> _audio;
    GameOverlayView* _overlayView;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _sceneTexture;
    CGContextRef _sceneContext;
    std::vector<uint8_t> _scenePixels;
    size_t _sceneWidth;
    size_t _sceneHeight;
    size_t _sceneBytesPerRow;
    CFTimeInterval _lastTime;
}

- (instancetype)initWithFrame:(NSRect)frame {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:device];
    if (self) {
        _audio = std::make_unique<AudioEngine>();
        AudioEngine* engine = _audio.get();
        _game.setAudioCallback([engine](const AudioEvent& event) {
            engine->queueEvent(event);
        });

        self.delegate = self;
        self.preferredFramesPerSecond = 60;
        self.enableSetNeedsDisplay = NO;
        self.paused = NO;
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        _commandQueue = [device newCommandQueue];
        [self buildPipeline];
        _overlayView = [[GameOverlayView alloc] initWithFrame:self.bounds owner:self];
        _overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_overlayView];
        _lastTime = CACurrentMediaTime();
    }
    return self;
}

- (void)dealloc {
    if (_sceneContext != nullptr) CGContextRelease(_sceneContext);
    [super dealloc];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
}

- (void)buildPipeline {
    NSError* error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:kPostProcessShaderSource options:nil error:&error];
    NSAssert(library != nil, @"Metal shader compile failed: %@", error);

    MTLRenderPipelineDescriptor* descriptor = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
    descriptor.vertexFunction = [library newFunctionWithName:@"postFXVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"postFXFragment"];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;

    _pipelineState = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    NSAssert(_pipelineState != nil, @"Metal pipeline creation failed: %@", error);
}

- (void)ensureSceneResourcesForDrawableSize:(CGSize)drawableSize {
    CGSize optimizedSize = optimizedSceneSizeForDrawableSize(drawableSize);
    size_t width = std::max<size_t>(1, static_cast<size_t>(optimizedSize.width));
    size_t height = std::max<size_t>(1, static_cast<size_t>(optimizedSize.height));
    if (width == _sceneWidth && height == _sceneHeight && _sceneTexture != nil && _sceneContext != nullptr) return;

    _sceneWidth = width;
    _sceneHeight = height;
    _sceneBytesPerRow = _sceneWidth * 4;
    _scenePixels.assign(_sceneBytesPerRow * _sceneHeight, 0);

    if (_sceneContext != nullptr) {
        CGContextRelease(_sceneContext);
        _sceneContext = nullptr;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    _sceneContext = CGBitmapContextCreate(_scenePixels.data(),
                                          _sceneWidth,
                                          _sceneHeight,
                                          8,
                                          _sceneBytesPerRow,
                                          colorSpace,
                                          kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    CGContextTranslateCTM(_sceneContext, 0.0, static_cast<CGFloat>(_sceneHeight));
    CGContextScaleCTM(_sceneContext, 1.0, -1.0);

    MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                  width:_sceneWidth
                                                                                                 height:_sceneHeight
                                                                                              mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageShaderRead;
    _sceneTexture = [self.device newTextureWithDescriptor:textureDescriptor];
}

- (void)renderSceneToBitmapWithBounds:(NSRect)bounds {
    if (_sceneContext == nullptr) return;

    CGContextSaveGState(_sceneContext);
    CGContextClearRect(_sceneContext, CGRectMake(0, 0, bounds.size.width, bounds.size.height));
    CGContextSetAllowsAntialiasing(_sceneContext, true);
    CGContextSetShouldAntialias(_sceneContext, true);

    NSGraphicsContext* graphicsContext = [NSGraphicsContext graphicsContextWithCGContext:_sceneContext flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphicsContext];

    [self drawBackground:_sceneContext bounds:bounds];
    [self drawRing:_sceneContext];
    [self drawMonsters:_sceneContext];
    [self drawParticles:_sceneContext];
    [self drawPulses:_sceneContext];

    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(_sceneContext);
}

- (void)mouseDown:(NSEvent*)event {
    juce::ignoreUnused(event);
    _game.mouseDown();
}

- (NSString*)stringForEvent:(NSEvent*)event {
    NSString* chars = event.charactersIgnoringModifiers.uppercaseString;
    if (event.keyCode == 36) return @"ENTER";
    if (event.keyCode == 49) return @"SPACE";
    if (chars.length == 0) return @"";
    unichar ch = [chars characterAtIndex:0];
    if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch]) return [NSString stringWithCharacters:&ch length:1];
    return @"";
}

- (void)keyDown:(NSEvent*)event {
    NSString* key = [self stringForEvent:event];
    _game.keyDown(key.UTF8String ? key.UTF8String : "");
}

- (void)keyUp:(NSEvent*)event {
    NSString* key = [self stringForEvent:event];
    _game.keyUp(key.UTF8String ? key.UTF8String : "");
}

- (BOOL)gameRunningForOverlay { return _game.running(); }
- (BOOL)showStartForOverlay { return _game.showStart(); }
- (BOOL)showGameOverForOverlay { return _game.showGameOver(); }
- (int)scoreForOverlay { return _game.score(); }
- (VisualStyle)visualStyleForOverlay { return _game.state().visualStyle; }

- (void)drawHUDInBounds:(NSRect)bounds {
    NSDictionary* scoreAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:34],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSDictionary* livesAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:22],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };

    NSString* score = [NSString stringWithFormat:@"%d", _game.score()];
    NSSize scoreSize = [score sizeWithAttributes:scoreAttrs];
    NSRect scoreChip = NSMakeRect(10, 10, scoreSize.width + 18, scoreSize.height + 12);
    drawGlassLabel(scoreChip, 10.0, [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.74], [NSColor colorWithCalibratedWhite:1.0 alpha:0.28]);
    strokeText(score, NSMakePoint(19, 17), scoreAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.95], 0, 0);
    [score drawAtPoint:NSMakePoint(19, 17) withAttributes:scoreAttrs];

    NSString* lives = [NSString stringWithFormat:@"Lives %d", _game.lives()];
    NSSize livesSize = [lives sizeWithAttributes:livesAttrs];
    NSRect livesChip = NSMakeRect(bounds.size.width - livesSize.width - 28, 14, livesSize.width + 20, livesSize.height + 12);
    drawGlassLabel(livesChip, 10.0, [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.74], [NSColor colorWithCalibratedWhite:1.0 alpha:0.28]);
    strokeText(lives, NSMakePoint(bounds.size.width - livesSize.width - 18, 20), livesAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.95], 0, 0);
    [lives drawAtPoint:NSMakePoint(bounds.size.width - livesSize.width - 18, 20) withAttributes:livesAttrs];

    ScaleState scale = _game.scaleState();
    NSDictionary* infoAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.75]
    };
    NSString* info = [NSString stringWithFormat:@"%s  •  %s", scale.levelName.c_str(), scale.displayName.c_str()];
    NSSize infoSize = [info sizeWithAttributes:infoAttrs];
    NSRect infoChip = NSMakeRect(12, 52, infoSize.width + 16, infoSize.height + 10);
    drawGlassLabel(infoChip, 9.0, [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.62], [NSColor colorWithCalibratedWhite:1.0 alpha:0.2]);
    strokeText(info, NSMakePoint(20, 57), infoAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.9], 0, 0);
    [info drawAtPoint:NSMakePoint(20, 57) withAttributes:infoAttrs];
}

- (void)drawGlassShards:(CGContextRef)ctx bounds:(NSRect)bounds baseHue:(double)baseHue {
    double width = bounds.size.width;
    double height = bounds.size.height;
    Vec2 center = _game.center();
    double pulse = _game.state().beatPulse;

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    for (int i = 0; i < 10; ++i) {
        double rainbowT = (baseHue / 360.0) + i * 0.14 + _game.state().elapsed * 0.065 + (i % 2 ? 0.08 : -0.05);
        Color glass = rainbowColor(rainbowT, 0.18 + (i % 3) * 0.07 + pulse * 0.025);
        double wobble = std::sin(_game.state().elapsed * 0.45 + i * 0.8) * (0.18 + pulse * 0.06);
        std::vector<Vec2> shard = {
            {lerp(0.0, width, std::fmod(0.07 * i + 0.11, 1.0)), lerp(0.0, height, std::fmod(0.19 * i + 0.08, 1.0))},
            polarPoint(center, std::min(width, height) * (0.18 + i * 0.038 + pulse * 0.02), -1.4 + i * 0.31 + wobble),
            polarPoint(center, std::min(width, height) * (0.46 + i * 0.028 + pulse * 0.04), -0.8 + i * 0.29 - wobble),
            {lerp(width, 0.0, std::fmod(0.13 * i + 0.27, 1.0)), lerp(height, 0.0, std::fmod(0.17 * i + 0.21, 1.0))}
        };
        fillPolygon(ctx, shard, toNSColor(glass));
        strokePolygon(ctx, shard, toNSColor(rainbowColor(rainbowT + 0.16, 0.36 + pulse * 0.05)), 1.8);
    }
    CGContextRestoreGState(ctx);

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
    for (int i = 0; i < 9; ++i) {
        std::vector<Vec2> lead = {
            polarPoint(center, std::min(width, height) * 0.1, i * 0.58 + _game.state().elapsed * 0.02),
            polarPoint(center, std::max(width, height) * 0.7, i * 0.58 + 0.18)
        };
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedRed:0.05 green:0.04 blue:0.03 alpha:0.55].CGColor);
        CGContextSetLineWidth(ctx, 7.0);
        CGContextMoveToPoint(ctx, lead[0].x, lead[0].y);
        CGContextAddLineToPoint(ctx, lead[1].x, lead[1].y);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

- (void)drawVolumetricLighting:(CGContextRef)ctx bounds:(NSRect)bounds hue:(double)baseHue {
    Vec2 center = _game.center();
    double width = bounds.size.width;
    double height = bounds.size.height;
    double pulse = _game.state().beatPulse;

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);

    drawRadialGradient(ctx, center, std::min(width, height) * 0.56, rainbowColor(baseHue / 360.0 + 0.05, 0.42 + pulse * 0.06), rainbowColor(baseHue / 360.0 + 0.05, 0.0));
    drawRadialGradient(ctx, {center.x, center.y - height * 0.18}, std::min(width, height) * 0.72, rainbowColor(baseHue / 360.0 + 0.33, 0.28 + pulse * 0.04), rainbowColor(baseHue / 360.0 + 0.33, 0.0));
    drawRadialGradient(ctx, {center.x + width * 0.14, center.y + height * 0.08}, std::min(width, height) * 0.64, rainbowColor(baseHue / 360.0 + 0.66, 0.26 + pulse * 0.04), rainbowColor(baseHue / 360.0 + 0.66, 0.0));

    for (int i = 0; i < 6; ++i) {
        double spread = lerp(-0.52, 0.52, i / 5.0);
        Vec2 origin{width * (0.08 + 0.14 * i), -height * 0.05};
        Vec2 a = polarPoint(center, std::max(width, height) * (0.14 + pulse * 0.03), -kPi / 2.0 + spread - 0.11);
        Vec2 b = polarPoint(center, std::max(width, height) * (0.58 + pulse * 0.06), -kPi / 2.0 + spread + 0.06);
        std::vector<Vec2> beam = {origin, a, b};
        Color beamColor = rainbowColor(baseHue / 360.0 + i * 0.16 + (i % 2 ? 0.12 : 0.0), 0.14 + pulse * 0.05);
        fillPolygon(ctx, beam, toNSColor(beamColor));
    }

    for (int i = 0; i < 4; ++i) {
        Color ray = rainbowColor(baseHue / 360.0 + 0.2 + i * 0.18, 0.16 + pulse * 0.04);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 40.0, toNSColor(withAlpha(ray, 0.82)).CGColor);
        CGContextSetStrokeColorWithColor(ctx, toNSColor(ray).CGColor);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineWidth(ctx, 30.0 - i * 3.8);
        Vec2 start{width * (0.08 + 0.17 * i), -10.0};
        Vec2 end = polarPoint(center, std::max(width, height) * (0.62 + pulse * 0.03), -1.18 + i * 0.34);
        CGContextMoveToPoint(ctx, start.x, start.y);
        CGContextAddLineToPoint(ctx, end.x, end.y);
        CGContextStrokePath(ctx);
    }

    CGContextRestoreGState(ctx);
}

- (void)drawBackground:(CGContextRef)ctx bounds:(NSRect)bounds {
    const GameState& state = _game.state();
    auto transition = _game.visualTransition();
    double width = bounds.size.width;
    double height = bounds.size.height;
    Vec2 center = _game.center();

    auto styleHue = [&](VisualStyle style) {
        return style == VisualStyle::Invaders ? 338.0 : (style == VisualStyle::Tempest ? 195.0 : 38.0);
    };
    auto styleSpeed = [&](VisualStyle style) {
        return style == VisualStyle::Rez ? 16.0 : (style == VisualStyle::Tempest ? 11.0 : 8.0);
    };

    double mix = transition.mix;
    double fromHue = styleHue(transition.fromStyle) + state.elapsed * styleSpeed(transition.fromStyle);
    double toHue = styleHue(transition.toStyle) + state.elapsed * styleSpeed(transition.toStyle);
    double baseHue = std::fmod(lerp(fromHue, toHue, mix), 360.0);

    drawLinearGradient(ctx, {0.0, 0.0}, {width, height},
                       rainbowColor(baseHue / 360.0 + 0.0, 0.32),
                       rainbowColor(baseHue / 360.0 + 0.34, 0.62));
    drawLinearGradient(ctx, {width, 0.0}, {0.0, height},
                       rainbowColor(baseHue / 360.0 + 0.68, 0.68),
                       rainbowColor(baseHue / 360.0 + 0.9, 0.0));
    drawRadialGradient(ctx, center, std::min(width, height) * 0.82,
                       rainbowColor(baseHue / 360.0 + 0.08, 0.5 + state.beatPulse * 0.05),
                       rainbowColor(baseHue / 360.0 + 0.08, 0.0));
    drawRadialGradient(ctx, {center.x - width * 0.18, center.y + height * 0.12}, std::min(width, height) * 0.58,
                       rainbowColor(baseHue / 360.0 + 0.52, 0.36 + state.beatPulse * 0.05),
                       rainbowColor(baseHue / 360.0 + 0.52, 0.0));

    [self drawGlassShards:ctx bounds:bounds baseHue:baseHue];
    [self drawVolumetricLighting:ctx bounds:bounds hue:baseHue];

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    if (transition.fromStyle == VisualStyle::Invaders || transition.toStyle == VisualStyle::Invaders) {
        double weight = (transition.fromStyle == VisualStyle::Invaders ? 1.0 - mix : 0.0) + (transition.toStyle == VisualStyle::Invaders ? mix : 0.0);
        weight = std::min(1.0, weight * 1.25 + (state.visualStyle == VisualStyle::Invaders ? 0.12 : 0.0));
        for (int i = 0; i < 7; ++i) {
            double y = 64 + i * 50;
            Color band = rainbowColor(baseHue / 360.0 + i * 0.14 + state.elapsed * 0.03, (0.28 + state.beatPulse * 0.07) * weight);
            fillRect(NSMakeRect(0, y, width, 24 + state.beatPulse * 3.0), toNSColor(band));
            fillRect(NSMakeRect(0, y + 6.0, width, 6.0 + state.beatPulse * 1.5), toNSColor(rainbowColor(baseHue / 360.0 + 0.22 + i * 0.08, 0.2 * weight)));
        }
    }

    if (transition.fromStyle == VisualStyle::Tempest || transition.toStyle == VisualStyle::Tempest) {
        double weight = (transition.fromStyle == VisualStyle::Tempest ? 1.0 - mix : 0.0) + (transition.toStyle == VisualStyle::Tempest ? mix : 0.0);
        for (int i = 0; i < 16; ++i) {
            double angle = (static_cast<double>(i) / 16.0) * kPi * 2.0 + state.elapsed * 0.05;
            Color c = rainbowColor(baseHue / 360.0 + i * 0.11 + (i % 3) * 0.05, 0.34 * weight + state.beatPulse * 0.04);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 22.0, toNSColor(withAlpha(c, 0.86 * weight)).CGColor);
            CGContextSetStrokeColorWithColor(ctx, toNSColor(c).CGColor);
            CGContextSetLineWidth(ctx, 2.2 + 1.9 * weight + state.beatPulse * 0.6);
            CGContextMoveToPoint(ctx, center.x, center.y);
            CGContextAddLineToPoint(ctx, center.x + std::cos(angle) * _game.outerSpawnRadius(), center.y + std::sin(angle) * _game.outerSpawnRadius());
            CGContextStrokePath(ctx);
        }
    }

    if (transition.fromStyle == VisualStyle::Rez || transition.toStyle == VisualStyle::Rez) {
        double weight = (transition.fromStyle == VisualStyle::Rez ? 1.0 - mix : 0.0) + (transition.toStyle == VisualStyle::Rez ? mix : 0.0);
        for (double r = 64.0; r < _game.outerSpawnRadius(); r += 58.0) {
            Color c = rainbowColor(baseHue / 360.0 + r * 0.0028 + state.elapsed * 0.035, 0.34 * weight + state.beatPulse * 0.05);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 24.0, toNSColor(withAlpha(c, 0.82 * weight)).CGColor);
            strokeCircle(ctx, center, r + state.beatPulse * 8.0, toNSColor(c), 2.2 + 3.0 * weight);
        }
    }
    CGContextRestoreGState(ctx);

    if (state.levelFlash > 0.0) fillRect(bounds, [NSColor colorWithCalibratedWhite:1.0 alpha:0.12 * state.levelFlash]);
}

- (void)drawRing:(CGContextRef)ctx {
    const GameState& state = _game.state();
    auto transition = _game.visualTransition();
    Vec2 center = _game.center();
    double rr = _game.ringRadius();

    auto styleHue = [&](VisualStyle style) {
        return style == VisualStyle::Invaders ? 332.0 : (style == VisualStyle::Tempest ? 188.0 : 26.0);
    };
    double hue = std::fmod(lerp(styleHue(transition.fromStyle), styleHue(transition.toStyle), transition.mix) + state.elapsed * 18.0, 360.0);

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    drawRadialGradient(ctx, center, rr * 3.2, rainbowColor(hue / 360.0 + 0.06, 0.34 + state.beatPulse * 0.06), rainbowColor(hue / 360.0 + 0.06, 0.0));
    drawRadialGradient(ctx, center, rr * 2.4, rainbowColor(hue / 360.0 + 0.48, 0.24 + state.beatPulse * 0.04), rainbowColor(hue / 360.0 + 0.48, 0.0));
    CGContextRestoreGState(ctx);

    if (transition.fromStyle == VisualStyle::Invaders || transition.toStyle == VisualStyle::Invaders) {
        double weight = (transition.fromStyle == VisualStyle::Invaders ? 1.0 - transition.mix : 0.0) + (transition.toStyle == VisualStyle::Invaders ? transition.mix : 0.0);
        weight = std::min(1.0, weight * 1.25 + (state.visualStyle == VisualStyle::Invaders ? 0.12 : 0.0));
        Color frame = rainbowColor(hue / 360.0 + 0.92, 0.62);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 30.0, toNSColor(withAlpha(frame, 0.98 * weight)).CGColor);
        fillRect(NSMakeRect(center.x - rr * 1.0, center.y - rr * 0.32, rr * 2.0, rr * 0.64), toNSColor(withAlpha(frame, 0.62 * weight)));
        fillRect(NSMakeRect(center.x - rr * 0.72, center.y - rr * 0.16, rr * 1.44, rr * 0.32), toNSColor(rainbowColor(hue / 360.0 + 0.18, 0.96 * weight)));
        fillRect(NSMakeRect(center.x - rr * 0.56, center.y - rr * 0.07, rr * 1.12, rr * 0.14), [NSColor colorWithCalibratedWhite:1.0 alpha:0.86 * weight]);
        fillRect(NSMakeRect(center.x - rr * 0.96, center.y - rr * 0.012, rr * 1.92, rr * 0.024), toNSColor(rainbowColor(hue / 360.0 + 0.34, 0.34 * weight)));
    }

    if (transition.fromStyle == VisualStyle::Tempest || transition.toStyle == VisualStyle::Tempest) {
        double weight = (transition.fromStyle == VisualStyle::Tempest ? 1.0 - transition.mix : 0.0) + (transition.toStyle == VisualStyle::Tempest ? transition.mix : 0.0);
        for (int i = 0; i < 3; ++i) {
            Color c = rainbowColor(hue / 360.0 + i * 0.16, 0.52 * weight + state.beatPulse * 0.04);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 26.0, toNSColor(withAlpha(c, 0.92 * weight)).CGColor);
            strokeCircle(ctx, center, rr + i * 14 + state.beatPulse * 6.0, toNSColor(c), std::max(1.7, (i == 0 ? 11.0 : 6.8) * weight));
        }
    }

    if (transition.fromStyle == VisualStyle::Rez || transition.toStyle == VisualStyle::Rez) {
        double weight = (transition.fromStyle == VisualStyle::Rez ? 1.0 - transition.mix : 0.0) + (transition.toStyle == VisualStyle::Rez ? transition.mix : 0.0);
        for (int i = 0; i < 5; ++i) {
            Color c = rainbowColor(hue / 360.0 + 0.08 + i * 0.13 + state.elapsed * 0.03, 0.48 * weight + state.beatPulse * 0.05);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 28.0, toNSColor(withAlpha(c, 0.92 * weight)).CGColor);
            strokeCircle(ctx, center, rr + i * 9 + state.beatPulse * 13.0, toNSColor(c), std::max(1.5, (i == 0 ? 7.0 : 4.4) * weight));
        }
    }
}

- (void)drawParticles:(CGContextRef)ctx {
    const GameState& state = _game.state();
    for (const auto& p : state.particles) {
        double alpha = std::max(0.0, p.life / p.maxLife);
        Color c = rainbowColor((p.pos.x * 0.0018 + p.pos.y * 0.0027 + state.elapsed * 0.22), alpha);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 24.0, toNSColor(withAlpha(c, alpha * 0.95)).CGColor);
        fillCircle(ctx, p.pos, std::max(2.8, p.size * 0.52), toNSColor(c));
    }
}

- (void)drawPulses:(CGContextRef)ctx {
    const GameState& state = _game.state();
    for (const auto& pulse : state.pulses) {
        double alpha = std::max(0.0, pulse.life / pulse.maxLife) * 0.72;
        CGContextSetBlendMode(ctx, kCGBlendModeScreen);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 36.0, toNSColor(withAlpha(pulse.color, alpha)).CGColor);
        strokeCircle(ctx, pulse.pos, pulse.radius, toNSColor(withAlpha(pulse.color, alpha)), 5.6);
        strokeCircle(ctx, pulse.pos, pulse.radius + 8.0, toNSColor(withAlpha(pulse.color, alpha * 0.55)), 2.4);
        drawRadialGradient(ctx, pulse.pos, pulse.radius * 1.7, withAlpha(pulse.color, alpha * 0.52), withAlpha(pulse.color, 0.0));
    }
}

- (void)drawMonsters:(CGContextRef)ctx {
    const GameState& state = _game.state();
    std::vector<int> targets = _game.currentTargets();
    std::unordered_set<int> targetSet(targets.begin(), targets.end());

    for (const auto& m : state.monsters) {
        bool isTarget = targetSet.count(m.id) > 0;
        Color c = rainbowColor((m.freq * 0.0018 + state.elapsed * 0.18));
        Color inner = mixColor(c, rainbowColor((m.freq * 0.0018 + state.elapsed * 0.18) + 0.18), 0.55);
        double size = std::max(18.0, m.size * 1.5);

        CGContextSetFillColorWithColor(ctx, toNSColor(c).CGColor);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:1.0 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 34.0, toNSColor(withAlpha(c, 0.98)).CGColor);
        drawRadialGradient(ctx, m.pos, size * 2.6, withAlpha(inner, 0.52), withAlpha(c, 0.0));

        if (m.style == VisualStyle::Invaders) {
            fillRect(NSMakeRect(m.pos.x - size * 0.75, m.pos.y - size * 0.35, size * 1.5, size * 0.7), toNSColor(withAlpha(c, 0.75)));
            fillRect(NSMakeRect(m.pos.x - size * 0.45, m.pos.y - size * 0.75, size * 0.28, size * 0.35), toNSColor(withAlpha(inner, 0.8)));
            fillRect(NSMakeRect(m.pos.x + size * 0.17, m.pos.y - size * 0.75, size * 0.28, size * 0.35), toNSColor(withAlpha(inner, 0.8)));
            fillRect(NSMakeRect(m.pos.x - size * 0.46, m.pos.y - size * 0.1, size * 0.92, size * 0.18), [NSColor colorWithCalibratedWhite:1.0 alpha:0.24]);
            CGContextStrokeRect(ctx, CGRectMake(m.pos.x - size * 0.75, m.pos.y - size * 0.35, size * 1.5, size * 0.7));
        } else if (m.style == VisualStyle::Tempest) {
            double angle = std::atan2(_game.center().y - m.pos.y, _game.center().x - m.pos.x) + kPi / 2.0;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, m.pos.x, m.pos.y);
            CGContextRotateCTM(ctx, angle);
            std::vector<Vec2> shard = {
                {0.0, -size},
                {size * 0.85, size * 0.75},
                {0.0, size * 0.36},
                {-size * 0.85, size * 0.75}
            };
            fillPolygon(ctx, shard, toNSColor(withAlpha(c, 0.74)));
            strokePolygon(ctx, shard, [NSColor colorWithCalibratedWhite:1.0 alpha:0.92], 2.4);
            fillPolygon(ctx, {{0.0, -size * 0.72}, {size * 0.28, size * 0.18}, {-size * 0.28, size * 0.18}}, toNSColor(withAlpha(inner, 0.65)));
            CGContextRestoreGState(ctx);
        } else {
            fillCircle(ctx, m.pos, size * 0.8, toNSColor(withAlpha(c, 0.74)));
            fillCircle(ctx, m.pos, size * 0.48, toNSColor(withAlpha(inner, 0.7)));
            strokeCircle(ctx, m.pos, size * 0.8, [NSColor colorWithCalibratedWhite:1.0 alpha:0.95], 2.5);
            if (isTarget) {
                Color lock = mixColor(c, makeColor(255, 255, 255), 0.55);
                CGContextSetShadowWithColor(ctx, CGSizeZero, 16.0, toNSColor(withAlpha(lock, 0.42)).CGColor);
                strokeCircle(ctx, m.pos, size * 1.12, toNSColor(withAlpha(lock, 0.95)), 3.5);
                CGContextSetStrokeColorWithColor(ctx, toNSColor(withAlpha(lock, 0.95)).CGColor);
                CGContextSetLineWidth(ctx, 3.0);
                CGContextMoveToPoint(ctx, m.pos.x - size * 1.4, m.pos.y);
                CGContextAddLineToPoint(ctx, m.pos.x + size * 1.4, m.pos.y);
                CGContextMoveToPoint(ctx, m.pos.x, m.pos.y - size * 1.4);
                CGContextAddLineToPoint(ctx, m.pos.x, m.pos.y + size * 1.4);
                CGContextStrokePath(ctx);
            }
        }

    }
}

- (void)drawMonsterLabelsInBounds:(NSRect)bounds {
    const GameState& state = _game.state();
    std::vector<int> targets = _game.currentTargets();
    std::unordered_set<int> targetSet(targets.begin(), targets.end());
    double sceneWidth = std::max(1.0, static_cast<double>(_sceneWidth));
    double sceneHeight = std::max(1.0, static_cast<double>(_sceneHeight));
    double sx = bounds.size.width / sceneWidth;
    double sy = bounds.size.height / sceneHeight;
    double uniformScale = std::min(sx, sy);

    NSDictionary* baseAttrs = @{
        NSForegroundColorAttributeName: NSColor.whiteColor
    };

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    for (const auto& m : state.monsters) {
        bool isTarget = targetSet.count(m.id) > 0;
        double size = std::max(18.0, m.size * 1.5) * uniformScale;
        NSPoint warpedPos = [self distortedOverlayPointForScenePoint:m.pos bounds:bounds];
        Vec2 pos{warpedPos.x, warpedPos.y};
        double badgeRadius = size * (isTarget ? 0.62 : 0.5);
        Color enemyCore = rainbowColor((m.freq * 0.0018 + state.elapsed * 0.18));
        Color enemyInner = mixColor(enemyCore, rainbowColor((m.freq * 0.0018 + state.elapsed * 0.18) + 0.18), 0.55);
        Color badgeFill = mixColor(enemyCore, makeColor(12, 14, 18), 0.68);
        Color badgeCenter = mixColor(enemyInner, makeColor(255, 255, 255), 0.22);
        Color rim = mixColor(enemyCore, makeColor(255, 255, 255), isTarget ? 0.6 : 0.42);
        Color outerGlow = withAlpha(enemyCore, isTarget ? 0.3 : 0.18);

        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeScreen);
        drawRadialGradient(ctx, pos, badgeRadius * (isTarget ? 1.95 : 1.55), outerGlow, withAlpha(enemyCore, 0.0));
        CGContextRestoreGState(ctx);

        fillCircle(ctx, pos, badgeRadius, toNSColor(withAlpha(badgeFill, 0.94)));
        drawRadialGradient(ctx, {pos.x - badgeRadius * 0.22, pos.y - badgeRadius * 0.26}, badgeRadius * 1.05, withAlpha(badgeCenter, 0.42), withAlpha(badgeCenter, 0.0));
        strokeCircle(ctx, pos, badgeRadius, toNSColor(withAlpha(rim, 0.96)), isTarget ? 3.4 : 2.6);
        strokeCircle(ctx, pos, badgeRadius - 3.0, [NSColor colorWithCalibratedWhite:1.0 alpha:0.34], 1.4);
        if (isTarget) strokeCircle(ctx, pos, badgeRadius + 4.0, toNSColor(withAlpha(rim, 0.58)), 1.8);

        NSMutableDictionary* attrs = [baseAttrs mutableCopy];
        attrs[NSFontAttributeName] = [NSFont boldSystemFontOfSize:std::max(30.0, m.size * 1.8 * uniformScale)];
        NSString* key = [NSString stringWithUTF8String:m.key.c_str()];
        NSSize sizeText = [key sizeWithAttributes:attrs];
        NSPoint p = NSMakePoint(pos.x - sizeText.width * 0.5, pos.y - sizeText.height * 0.5);
        strokeText(key, p, attrs, [NSColor colorWithCalibratedWhite:0.0 alpha:1.0], 0, 1);
        strokeText(key, p, attrs, [NSColor colorWithCalibratedWhite:0.0 alpha:1.0], 0, 0);
        strokeText(key, p, attrs, [NSColor colorWithCalibratedWhite:0.0 alpha:1.0], 1, 0);
        [key drawAtPoint:p withAttributes:attrs];
    }
}

- (NSPoint)distortedOverlayPointForScenePoint:(Vec2)scenePoint bounds:(NSRect)bounds {
    double sceneWidth = std::max(1.0, static_cast<double>(_sceneWidth));
    double sceneHeight = std::max(1.0, static_cast<double>(_sceneHeight));
    double uvx = std::clamp(scenePoint.x / sceneWidth, 0.0, 1.0);
    double uvy = 1.0 - std::clamp(scenePoint.y / sceneHeight, 0.0, 1.0);

    Vec2 centered{uvx * 2.0 - 1.0, uvy * 2.0 - 1.0};
    double radius = std::sqrt(centered.x * centered.x + centered.y * centered.y);
    Vec2 dir{0.0, 0.0};
    if (radius > 0.0001) dir = {centered.x / radius, centered.y / radius};

    const GameState& state = _game.state();
    double time = state.elapsed;
    double wave = std::sin((uvy * 13.0 + time * 0.55) * 2.0) * 0.5 + std::sin((uvx * 9.0 - time * 0.27) * 3.0) * 0.5;
    double swirl = std::sin(radius * 22.0 - time * 1.35) * 0.0016;
    double distortionAmount = state.visualStyle == VisualStyle::Tempest ? 0.018 : (state.visualStyle == VisualStyle::Rez ? 0.015 : 0.011);

    Vec2 distortion{
        dir.x * radius * radius * distortionAmount + dir.y * swirl + dir.x * wave * 0.0012,
        dir.y * radius * radius * distortionAmount - dir.x * swirl + dir.y * wave * 0.0012
    };

    double distortedX = std::clamp(uvx + distortion.x, 0.0, 1.0);
    double distortedY = std::clamp(uvy + distortion.y, 0.0, 1.0);

    return NSMakePoint(distortedX * bounds.size.width, distortedY * bounds.size.height);
}

- (void)drawOverlayInBounds:(NSRect)bounds title:(NSString*)title subtitle:(NSString*)subtitle footer:(NSString*)footer {
    fillRect(bounds, [NSColor colorWithCalibratedWhite:0 alpha:0.55]);

    NSRect card = NSInsetRect(bounds, std::max(24.0, bounds.size.width * 0.18), std::max(48.0, bounds.size.height * 0.22));
    double t = _game.state().elapsed;
    double pulse = 0.5 + 0.5 * std::sin(t * 2.4);

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    drawRadialGradient(ctx, {NSMidX(card), NSMidY(card)}, card.size.width * 0.55, rainbowColor(0.92 + t * 0.04, 0.26 + pulse * 0.08), rainbowColor(0.92 + t * 0.04, 0.0));
    drawRadialGradient(ctx, {NSMidX(card) - card.size.width * 0.18, NSMidY(card) + card.size.height * 0.1}, card.size.width * 0.42, rainbowColor(0.55 + t * 0.03, 0.2 + pulse * 0.06), rainbowColor(0.55 + t * 0.03, 0.0));
    for (int i = 0; i < 6; ++i) {
        double y = card.origin.y + 28.0 + i * (card.size.height - 56.0) / 5.0;
        Color stripe = rainbowColor(0.9 + i * 0.12 + t * 0.05, 0.14 + pulse * 0.03);
        fillRect(NSMakeRect(card.origin.x + 18.0, y, card.size.width - 36.0, 10.0 + pulse * 2.0), toNSColor(stripe));
    }
    CGContextRestoreGState(ctx);

    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:card xRadius:12 yRadius:12];
    [[NSColor colorWithCalibratedRed:0.03 green:0.035 blue:0.05 alpha:0.9] setFill];
    [path fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.92] setStroke];
    [path setLineWidth:3.0];
    [path stroke];

    NSBezierPath* innerPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(card, 10.0, 10.0) xRadius:10 yRadius:10];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] setStroke];
    [innerPath setLineWidth:1.4];
    [innerPath stroke];

    NSDictionary* titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:std::min(82.0, bounds.size.width * 0.086)],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSDictionary* subtitleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:22],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1 alpha:0.85]
    };
    NSDictionary* footerAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1 alpha:0.72]
    };

    NSSize titleSize = [title sizeWithAttributes:titleAttrs];
    NSPoint titlePoint = NSMakePoint(NSMidX(card) - titleSize.width * 0.5, NSMinY(card) + 46);
    drawRadialGradient(ctx, {NSMidX(card), titlePoint.y + titleSize.height * 0.55}, titleSize.width * 0.7, rainbowColor(0.14 + t * 0.03, 0.2), rainbowColor(0.14 + t * 0.03, 0.0));
    strokeText(title, titlePoint, titleAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.96], 0, 0);
    [title drawAtPoint:titlePoint withAttributes:titleAttrs];

    NSSize subtitleSize = [subtitle sizeWithAttributes:subtitleAttrs];
    NSPoint subtitlePoint = NSMakePoint(NSMidX(card) - subtitleSize.width * 0.5, NSMinY(card) + 46 + titleSize.height + 20);
    drawGlassLabel(NSInsetRect(NSMakeRect(subtitlePoint.x, subtitlePoint.y, subtitleSize.width, subtitleSize.height), -10, -6),
                   8.0,
                   [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.58],
                   [NSColor colorWithCalibratedWhite:1.0 alpha:0.18]);
    strokeText(subtitle, subtitlePoint, subtitleAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.92], 0, 0);
    [subtitle drawAtPoint:subtitlePoint withAttributes:subtitleAttrs];

    NSSize footerSize = [footer sizeWithAttributes:footerAttrs];
    NSPoint footerPoint = NSMakePoint(NSMidX(card) - footerSize.width * 0.5, NSMaxY(card) - footerSize.height - 46);
    drawGlassLabel(NSInsetRect(NSMakeRect(footerPoint.x, footerPoint.y, footerSize.width, footerSize.height), -10, -6),
                   8.0,
                   [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.52],
                   [NSColor colorWithCalibratedWhite:1.0 alpha:0.18]);
    strokeText(footer, footerPoint, footerAttrs, [NSColor colorWithCalibratedWhite:0.0 alpha:0.92], 0, 0);
    [footer drawAtPoint:footerPoint withAttributes:footerAttrs];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    juce::ignoreUnused(view);
    [self ensureSceneResourcesForDrawableSize:size];
}

- (void)drawInMTKView:(MTKView*)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor* passDescriptor = view.currentRenderPassDescriptor;
    if (drawable == nil || passDescriptor == nil) return;

    CFTimeInterval now = CACurrentMediaTime();
    double dt = std::min(0.033, now - _lastTime);
    _lastTime = now;

    [self ensureSceneResourcesForDrawableSize:view.drawableSize];

    NSRect sceneBounds = NSMakeRect(0.0, 0.0, static_cast<CGFloat>(_sceneWidth), static_cast<CGFloat>(_sceneHeight));
    _game.setViewport(sceneBounds.size.width, sceneBounds.size.height);
    _game.update(dt);
    [self renderSceneToBitmapWithBounds:sceneBounds];

    MTLRegion region = MTLRegionMake2D(0, 0, _sceneWidth, _sceneHeight);
    [_sceneTexture replaceRegion:region mipmapLevel:0 withBytes:_scenePixels.data() bytesPerRow:_sceneBytesPerRow];

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    [encoder setRenderPipelineState:_pipelineState];
    [encoder setFragmentTexture:_sceneTexture atIndex:0];

    struct PostFXUniforms {
        simd::float2 resolution;
        float time;
        float bloomStrength;
        float aberration;
        float distortion;
        float beatPulse;
    } uniforms;

    uniforms.resolution = simd_make_float2(static_cast<float>(_sceneWidth), static_cast<float>(_sceneHeight));
    uniforms.time = static_cast<float>(_game.state().elapsed);
    uniforms.bloomStrength = _game.state().visualStyle == VisualStyle::Rez ? 1.28f : (_game.state().visualStyle == VisualStyle::Tempest ? 1.1f : 0.96f);
    uniforms.aberration = _game.state().visualStyle == VisualStyle::Rez ? 3.4f : 2.3f;
    uniforms.distortion = _game.state().visualStyle == VisualStyle::Tempest ? 0.016f : (_game.state().visualStyle == VisualStyle::Rez ? 0.013f : 0.010f);
    uniforms.beatPulse = static_cast<float>(_game.state().beatPulse);

    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    [_overlayView setNeedsDisplay:YES];
}

@end

@implementation GameOverlayView {
    GameView* _owner;
}

- (instancetype)initWithFrame:(NSRect)frame owner:(GameView*)owner {
    self = [super initWithFrame:frame];
    if (self) {
        _owner = owner;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSView*)hitTest:(NSPoint)point {
    juce::ignoreUnused(point);
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    juce::ignoreUnused(dirtyRect);
    if (_owner == nil) return;
    NSRect bounds = self.bounds;
    [_owner drawMonsterLabelsInBounds:bounds];
    [_owner drawHUDInBounds:bounds];

    if ([_owner visualStyleForOverlay] == VisualStyle::Rez && [_owner gameRunningForOverlay]) {
        NSDictionary* hintAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1 alpha:0.85]
        };
        NSString* hint = @"REZ MODE";
        NSSize size = [hint sizeWithAttributes:hintAttrs];
        drawGlassLabel(NSMakeRect(NSMidX(bounds) - size.width * 0.5 - 8, bounds.size.height - 36, size.width + 16, size.height + 8),
                       8.0,
                       [NSColor colorWithCalibratedRed:0.02 green:0.03 blue:0.05 alpha:0.72],
                       [NSColor colorWithCalibratedWhite:1.0 alpha:0.24]);
        strokeText(hint, NSMakePoint(NSMidX(bounds) - size.width * 0.5, bounds.size.height - 32), hintAttrs, [NSColor colorWithCalibratedWhite:0 alpha:1.0], 0, 0);
        [hint drawAtPoint:NSMakePoint(NSMidX(bounds) - size.width * 0.5, bounds.size.height - 32) withAttributes:hintAttrs];
    }

    if ([_owner showStartForOverlay]) {
        [_owner drawOverlayInBounds:bounds title:@"Note Defence" subtitle:@"Hit the right key. Survive three arcade phases." footer:@"Press Enter or click to start"];
    } else if ([_owner showGameOverForOverlay]) {
        NSString* subtitle = [NSString stringWithFormat:@"Final score: %d", [_owner scoreForOverlay]];
        [_owner drawOverlayInBounds:bounds title:@"Game Over" subtitle:subtitle footer:@"Press R, Enter, or click to play again"];
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow* window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    juce::ignoreUnused(notification);
    NSRect frame = NSMakeRect(0, 0, 1280, 720);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Note Defence";
    self.window.contentView = [[GameView alloc] initWithFrame:frame];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    juce::ignoreUnused(sender);
    return YES;
}

@end

int main(int argc, const char * argv[]) {
    juce::ignoreUnused(argc, argv);
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
