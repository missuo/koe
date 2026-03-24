#include "cue.h"
#include <mmsystem.h>

extern "C" {
#include "koe_core.h"
}

void CuePlayer::reloadFeedbackConfig() {
    SPFeedbackConfig cfg = sp_core_get_feedback_config();
    m_startEnabled = cfg.start_sound;
    m_stopEnabled = cfg.stop_sound;
    m_errorEnabled = cfg.error_sound;
}

void CuePlayer::playStart() {
    if (m_startEnabled) {
        PlaySoundW(L"DeviceConnect", nullptr, SND_ALIAS | SND_ASYNC);
    }
}

void CuePlayer::playStop() {
    if (m_stopEnabled) {
        PlaySoundW(L"DeviceDisconnect", nullptr, SND_ALIAS | SND_ASYNC);
    }
}

void CuePlayer::playError() {
    if (m_errorEnabled) {
        PlaySoundW(L"SystemHand", nullptr, SND_ALIAS | SND_ASYNC);
    }
}
