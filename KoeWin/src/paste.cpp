#include "paste.h"

void PasteManager::simulatePaste() {
    // 4 INPUT events: Ctrl down, V down, V up, Ctrl up
    INPUT inputs[4] = {};

    // Ctrl down
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_CONTROL;

    // V down
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = 0x56;  // 'V'

    // V up
    inputs[2].type = INPUT_KEYBOARD;
    inputs[2].ki.wVk = 0x56;
    inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    // Ctrl up
    inputs[3].type = INPUT_KEYBOARD;
    inputs[3].ki.wVk = VK_CONTROL;
    inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(4, inputs, sizeof(INPUT));
    OutputDebugStringA("[Koe] Ctrl+V simulated\n");
}
