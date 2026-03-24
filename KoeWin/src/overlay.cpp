#include "overlay.h"
#include <objidl.h>
#include <gdiplus.h>
#include <cmath>
#include <cstring>

using namespace Gdiplus;

// Geometry (in pixels, scaled for ~96 DPI)
static const int kPillHeight = 36;
static const int kPillCornerRadius = 18;
static const int kBottomMargin = 8;
static const int kHorizontalPad = 14;
static const int kIconAreaWidth = 28;
static const int kIconTextGap = 6;

// Animation
static const int kAnimIntervalMs = 33;  // ~30 FPS
static const int kFadeInFrames = 6;     // 0.2s at 30fps
static const int kFadeOutFrames = 9;    // 0.3s at 30fps

// Overlay modes
enum OverlayMode { ModeNone = 0, ModeWaveform = 1, ModeProcessing = 2, ModeSuccess = 3, ModeError = 4 };

static OverlayPanel* g_overlay = nullptr;

LRESULT CALLBACK OverlayPanel::overlayWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_TIMER && wParam == TIMER_OVERLAY_ANIM) {
        if (g_overlay) g_overlay->onAnimationTimer();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

OverlayPanel::OverlayPanel(HINSTANCE hInstance) {
    g_overlay = this;
    createWindow(hInstance);
}

OverlayPanel::~OverlayPanel() {
    KillTimer(m_hwnd, TIMER_OVERLAY_ANIM);
    if (m_hwnd) DestroyWindow(m_hwnd);
    if (g_overlay == this) g_overlay = nullptr;
}

void OverlayPanel::createWindow(HINSTANCE hInstance) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = overlayWndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = L"KoeOverlay";
    RegisterClassExW(&wc);

    m_hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"KoeOverlay", L"", WS_POPUP,
        0, 0, 200, kPillHeight,
        nullptr, nullptr, hInstance, nullptr
    );

    // Do NOT call SetLayeredWindowAttributes here — it makes subsequent
    // UpdateLayeredWindow calls fail.  Alpha is controlled exclusively
    // via UpdateLayeredWindow in render().
}

void OverlayPanel::updateState(const char* state) {
    m_currentState = state;
    m_tick = 0;

    KillTimer(m_hwnd, TIMER_OVERLAY_ANIM);

    if (strcmp(state, "idle") == 0 || strcmp(state, "completed") == 0) {
        hide();
        return;
    }

    // Map state to visual params (same as macOS SPOverlayPanel)
    if (strncmp(state, "recording", 9) == 0) {
        m_statusText = L"Listening\x2026";
        m_accentColor = RGB(255, 82, 82);
        m_mode = ModeWaveform;
    } else if (strcmp(state, "connecting_asr") == 0) {
        m_statusText = L"Connecting\x2026";
        m_accentColor = RGB(255, 199, 71);
        m_mode = ModeProcessing;
    } else if (strcmp(state, "finalizing_asr") == 0) {
        m_statusText = L"Recognizing\x2026";
        m_accentColor = RGB(89, 199, 255);
        m_mode = ModeProcessing;
    } else if (strcmp(state, "correcting") == 0) {
        m_statusText = L"Thinking\x2026";
        m_accentColor = RGB(140, 153, 255);
        m_mode = ModeProcessing;
    } else if (strncmp(state, "preparing_paste", 15) == 0 || strcmp(state, "pasting") == 0) {
        m_statusText = L"Pasting\x2026";
        m_accentColor = RGB(77, 217, 115);
        m_mode = ModeSuccess;
    } else if (strcmp(state, "error") == 0 || strcmp(state, "failed") == 0) {
        m_statusText = L"Error";
        m_accentColor = RGB(255, 82, 82);
        m_mode = ModeError;
    } else {
        m_statusText = L"Working\x2026";
        m_accentColor = RGB(89, 199, 255);
        m_mode = ModeProcessing;
    }

    resizeAndCenter();
    render();
    show();
    SetTimer(m_hwnd, TIMER_OVERLAY_ANIM, kAnimIntervalMs, nullptr);
}

void OverlayPanel::onAnimationTimer() {
    m_tick++;

    // Handle fade animation
    if (m_hiding) {
        m_alpha -= 1.0f / kFadeOutFrames;
        if (m_alpha <= 0.0f) {
            m_alpha = 0.0f;
            m_hiding = false;
            m_visible = false;
            ShowWindow(m_hwnd, SW_HIDE);
            KillTimer(m_hwnd, TIMER_OVERLAY_ANIM);
            return;
        }
        render();
        return;
    }

    if (m_visible && m_alpha < 1.0f) {
        m_alpha += 1.0f / kFadeInFrames;
        if (m_alpha > 1.0f) m_alpha = 1.0f;
    }

    render();
}

void OverlayPanel::show() {
    m_hiding = false;
    m_visible = true;
    if (m_alpha < 0.01f) m_alpha = 0.01f;
    ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
}

void OverlayPanel::hide() {
    if (!m_visible) return;
    m_hiding = true;
    // Keep timer running for fade-out
    if (!IsWindow(m_hwnd)) return;
    SetTimer(m_hwnd, TIMER_OVERLAY_ANIM, kAnimIntervalMs, nullptr);
}

void OverlayPanel::resizeAndCenter() {
    // Measure text width
    HDC hdc = GetDC(nullptr);
    Gdiplus::Graphics gMeasure(hdc);
    Gdiplus::Font font(L"Segoe UI", 13.0f, FontStyleRegular, UnitPixel);
    RectF textBounds;
    gMeasure.MeasureString(m_statusText, -1, &font, PointF(0, 0), &textBounds);
    ReleaseDC(nullptr, hdc);

    int textW = static_cast<int>(textBounds.Width) + 2;
    int pillW = kHorizontalPad + kIconAreaWidth + kIconTextGap + textW + kHorizontalPad;

    // Position at bottom center of primary monitor work area
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(MonitorFromWindow(m_hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);

    int x = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - pillW) / 2;
    int y = mi.rcWork.bottom - kPillHeight - kBottomMargin;

    SetWindowPos(m_hwnd, HWND_TOPMOST, x, y, pillW, kPillHeight,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void OverlayPanel::render() {
    RECT rc;
    GetWindowRect(m_hwnd, &rc);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;

    // Create a 32-bit ARGB bitmap
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;  // Top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;

    void* bits = nullptr;
    HDC hdcScreen = GetDC(nullptr);
    HDC hdcMem = CreateCompatibleDC(hdcScreen);
    HBITMAP hBmp = CreateDIBSection(hdcMem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ oldBmp = SelectObject(hdcMem, hBmp);

    // Draw with GDI+
    {
        Graphics g(hdcMem);
        g.SetSmoothingMode(SmoothingModeAntiAlias);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);
        g.Clear(Color(0, 0, 0, 0));

        // Background pill
        GraphicsPath pillPath;
        float fw = static_cast<float>(w);
        float fh = static_cast<float>(h);
        float r = static_cast<float>(kPillCornerRadius);
        float d = r * 2;
        pillPath.AddArc(0.0f, 0.0f, d, d, 180.0f, 90.0f);
        pillPath.AddArc(fw - d, 0.0f, d, d, 270.0f, 90.0f);
        pillPath.AddArc(fw - d, fh - d, d, d, 0.0f, 90.0f);
        pillPath.AddArc(0.0f, fh - d, d, d, 90.0f, 90.0f);
        pillPath.CloseFigure();

        SolidBrush bgBrush(Color(178, 0, 0, 0));  // 70% black
        g.FillPath(&bgBrush, &pillPath);

        // Subtle border
        Pen borderPen(Color(25, 255, 255, 255), 0.5f);  // 10% white
        g.DrawPath(&borderPen, &pillPath);

        // Icon area
        float iconCenterX = kHorizontalPad + kIconAreaWidth / 2.0f;
        float centerY = fh / 2.0f;

        BYTE acR = GetRValue(m_accentColor);
        BYTE acG = GetGValue(m_accentColor);
        BYTE acB = GetBValue(m_accentColor);

        if (m_mode == ModeWaveform) {
            // 5 animated waveform bars
            int barCount = 5;
            float barWidth = 3.0f;
            float barSpacing = 2.0f;
            float totalW = barCount * barWidth + (barCount - 1) * barSpacing;
            float startX = iconCenterX - totalW / 2.0f;
            for (int i = 0; i < barCount; i++) {
                double phase = (double)m_tick * 0.12 + (double)i * 1.1;
                float t = static_cast<float>(0.5 + 0.5 * sin(phase));
                float bh = 3.0f + t * 13.0f;
                BYTE a = static_cast<BYTE>(140 + 115 * t);
                SolidBrush brush(Color(a, acR, acG, acB));
                float x = startX + i * (barWidth + barSpacing);
                float y = centerY - bh / 2.0f;
                g.FillRectangle(&brush, x, y, barWidth, bh);
            }
        } else if (m_mode == ModeProcessing) {
            // 3 bouncing dots
            int dotCount = 3;
            float dotSpacing = 8.0f;
            float totalW = (dotCount - 1) * dotSpacing;
            float startX = iconCenterX - totalW / 2.0f;
            for (int i = 0; i < dotCount; i++) {
                double phase = (double)m_tick * 0.15 - (double)i * 0.9;
                float bounce = static_cast<float>(fmax(0.0, sin(phase)));
                float rad = 2.5f + bounce * 1.5f;
                BYTE a = static_cast<BYTE>(89 + 166 * bounce);
                float offsetY = -bounce * 3.0f;
                SolidBrush brush(Color(a, acR, acG, acB));
                float x = startX + i * dotSpacing;
                g.FillEllipse(&brush, x - rad, centerY - rad + offsetY, rad * 2, rad * 2);
            }
        } else if (m_mode == ModeSuccess) {
            // Animated checkmark
            float progress = fmin(1.0f, (float)m_tick / 12.0f);
            Pen pen(Color(242, acR, acG, acB), 2.0f);
            pen.SetLineCap(LineCapRound, LineCapRound, DashCapRound);
            PointF p0(iconCenterX - 6, centerY + 1);
            PointF p1(iconCenterX - 1.5f, centerY + 5);
            PointF p2(iconCenterX + 7, centerY - 4);
            if (progress <= 0.4f) {
                float t = progress / 0.4f;
                PointF end(p0.X + (p1.X - p0.X) * t, p0.Y + (p1.Y - p0.Y) * t);
                g.DrawLine(&pen, p0, end);
            } else {
                float t = (progress - 0.4f) / 0.6f;
                PointF end(p1.X + (p2.X - p1.X) * t, p1.Y + (p2.Y - p1.Y) * t);
                g.DrawLine(&pen, p0, p1);
                g.DrawLine(&pen, p1, end);
            }
        } else if (m_mode == ModeError) {
            // X mark
            Pen pen(Color(242, acR, acG, acB), 2.0f);
            pen.SetLineCap(LineCapRound, LineCapRound, DashCapRound);
            float arm = 5.0f;
            g.DrawLine(&pen, iconCenterX - arm, centerY - arm, iconCenterX + arm, centerY + arm);
            g.DrawLine(&pen, iconCenterX + arm, centerY - arm, iconCenterX - arm, centerY + arm);
        }

        // Text
        Font font(L"Segoe UI", 13.0f, FontStyleRegular, UnitPixel);
        SolidBrush textBrush(Color(234, 255, 255, 255));  // 92% white
        float textX = static_cast<float>(kHorizontalPad + kIconAreaWidth + kIconTextGap);
        RectF textBounds;
        g.MeasureString(m_statusText, -1, &font, PointF(0, 0), &textBounds);
        float textY = (fh - textBounds.Height) / 2.0f;
        g.DrawString(m_statusText, -1, &font, PointF(textX, textY), &textBrush);
    }

    // Update layered window
    POINT ptSrc = { 0, 0 };
    SIZE sizeWnd = { w, h };
    POINT ptWnd;
    {
        RECT wr;
        GetWindowRect(m_hwnd, &wr);
        ptWnd = { wr.left, wr.top };
    }
    BLENDFUNCTION blend = {};
    blend.BlendOp = AC_SRC_OVER;
    blend.SourceConstantAlpha = static_cast<BYTE>(m_alpha * 255);
    blend.AlphaFormat = AC_SRC_ALPHA;

    UpdateLayeredWindow(m_hwnd, hdcScreen, &ptWnd, &sizeWnd, hdcMem, &ptSrc, 0, &blend, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
}
