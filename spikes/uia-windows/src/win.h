// Single translation unit for the translate-c build step.
//
// COBJMACROS is not used: this file implements PROVIDER interfaces rather than
// calling client ones, so the vtables are built by hand.
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
#include <uiautomation.h>
