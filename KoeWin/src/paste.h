#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

class PasteManager {
public:
    // Simulate Ctrl+V paste via SendInput
    void simulatePaste();
};
