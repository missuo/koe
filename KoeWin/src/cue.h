#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

class CuePlayer {
public:
    void reloadFeedbackConfig();
    void playStart();
    void playStop();
    void playError();

private:
    bool m_startEnabled = true;
    bool m_stopEnabled = true;
    bool m_errorEnabled = true;
};
