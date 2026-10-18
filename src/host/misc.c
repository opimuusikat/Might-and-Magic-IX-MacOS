// advapi32 (empty registry), ole32, version.dll, winmm (timer only; no mixer/aux/CD devices),
// wsock32 and dplayx (single player: networking reports "unavailable").
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "shims.h"

SHIM(RegOpenKeyExA) { RET(c, 2, 5); }
SHIM(RegCreateKeyExA) { if (ARG(c, 7)) P32(ARG(c, 7), 0x00060001); if (ARG(c, 8)) P32(ARG(c, 8), 1); RET(c, 0, 9); }
SHIM(RegQueryValueExA) { RET(c, 2, 6); }
SHIM(RegSetValueExA) { RET(c, 0, 6); }
SHIM(RegCloseKey) { RET(c, 0, 1); }

SHIM(CoInitialize) { RET(c, 0, 1); }
SHIM(CoUninitialize) { RET(c, 0, 0); }
SHIM(CoCreateInstance) {
    fprintf(stderr, "[ole] CoCreateInstance {%08x-...} -> REGDB_E_CLASSNOTREG\n", G32(ARG(c, 0)));
    if (ARG(c, 4)) P32(ARG(c, 4), 0);
    RET(c, 0x80040154u, 5);
}

SHIM(GetFileVersionInfoSizeA) { if (ARG(c, 1)) P32(ARG(c, 1), 0); SETERR(1813); RET(c, 0, 2); }
SHIM(GetFileVersionInfoA) { RET(c, 0, 4); }
SHIM(VerQueryValueA) { RET(c, 0, 4); }

SHIM(timeGetTime) { RET(c, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000ull), 0); }
SHIM(auxGetNumDevs) { RET(c, 0, 0); }
SHIM(auxGetDevCapsA) { RET(c, 2 /* MMSYSERR_BADDEVICEID */, 3); }
SHIM(auxGetVolume) { RET(c, 2, 2); }
SHIM(auxSetVolume) { RET(c, 2, 2); }
SHIM(mixerGetNumDevs) { RET(c, 0, 0); }
SHIM(mixerOpen) { RET(c, 2, 5); }
SHIM(mixerClose) { RET(c, 5, 1); }
SHIM(mixerGetLineInfoA) { RET(c, 5, 3); }
SHIM(mixerGetLineControlsA) { RET(c, 5, 3); }
SHIM(mixerGetControlDetailsA) { RET(c, 5, 3); }
SHIM(mixerSetControlDetails) { RET(c, 5, 3); }
SHIM(mciSendCommandA) { RET(c, 275 /* MCIERR_DEVICE_NOT_INSTALLED-ish */, 4); }

// wsock32: WSAStartup succeeds (the engine only initialises it), every socket call fails
SHIM(WSAStartup) {
    uint32_t d = ARG(c, 1);
    if (d) { memset(MEM + d, 0, 400); P16(d, 0x0101); P16(d + 2, 0x0202); strcpy((char *)MEM + d + 4, "WinSock 2.0"); strcpy((char *)MEM + d + 261, "Running"); P16(d + 390, 32); P16(d + 392, 65467); }
    RET(c, 0, 2);
}
SHIM(WSACleanup) { RET(c, 0, 0); }
SHIM(WSAGetLastError) { RET(c, 10050 /* WSAENETDOWN */, 0); }
SHIM(socket) { RET(c, 0xFFFFFFFFu, 3); }
SHIM(closesocket) { RET(c, 0, 1); }
SHIM(bind) { RET(c, 0xFFFFFFFFu, 3); }
SHIM(setsockopt) { RET(c, 0xFFFFFFFFu, 5); }
SHIM(ioctlsocket) { RET(c, 0xFFFFFFFFu, 3); }
SHIM(getsockname) { RET(c, 0xFFFFFFFFu, 3); }
SHIM(recvfrom) { RET(c, 0xFFFFFFFFu, 6); }
SHIM(sendto) { RET(c, 0xFFFFFFFFu, 6); }
SHIM(select) { RET(c, 0, 5); }
SHIM(gethostname) { uint32_t b = ARG(c, 0), n = ARG(c, 1); if (n > 10) strcpy((char *)MEM + b, "localhost"); RET(c, 0, 2); }
SHIM(gethostbyname) { RET(c, 0, 1); }
SHIM(inet_addr) { RET(c, 0xFFFFFFFFu, 1); }
SHIM(htonl) { RET(c, __builtin_bswap32(ARG(c, 0)), 1); }
SHIM(ntohl) { RET(c, __builtin_bswap32(ARG(c, 0)), 1); }
SHIM(htons) { RET(c, __builtin_bswap16((uint16_t)ARG(c, 0)), 1); }
SHIM(ntohs) { RET(c, __builtin_bswap16((uint16_t)ARG(c, 0)), 1); }

// dplayx ordinals: 1 DirectPlayCreate(3), 2 DirectPlayEnumerateA(2), 4 DirectPlayLobbyCreateA(5)
static void dplay1(CPU *c) { RET(c, 0x80004005u, 3); }
static void dplay2(CPU *c) { RET(c, 0, 2); }
static void dplay4(CPU *c) { RET(c, 0x80004005u, 5); }

static const Shim misc_list[] = {
    E(RegOpenKeyExA) E(RegCreateKeyExA) E(RegQueryValueExA) E(RegSetValueExA) E(RegCloseKey)
    E(CoInitialize) E(CoUninitialize) E(CoCreateInstance)
    E(GetFileVersionInfoSizeA) E(GetFileVersionInfoA) E(VerQueryValueA)
    E(timeGetTime) E(auxGetNumDevs) E(auxGetDevCapsA) E(auxGetVolume) E(auxSetVolume) E(mixerGetNumDevs) E(mixerOpen)
    E(mixerClose) E(mixerGetLineInfoA) E(mixerGetLineControlsA) E(mixerGetControlDetailsA) E(mixerSetControlDetails)
    E(mciSendCommandA)
    E(WSAStartup) E(WSACleanup) E(WSAGetLastError) E(socket) E(closesocket) E(bind) E(setsockopt) E(ioctlsocket)
    E(getsockname) E(recvfrom) E(sendto) E(select) E(gethostname) E(gethostbyname) E(inet_addr) E(htonl) E(ntohl)
    E(htons) E(ntohs)
    {"wsock32#2", bind_}, {"wsock32#3", closesocket_}, {"wsock32#6", getsockname_}, {"wsock32#8", htonl_}, {"wsock32#9", htons_},
    {"wsock32#10", inet_addr_}, {"wsock32#12", ioctlsocket_}, {"wsock32#14", ntohl_}, {"wsock32#15", ntohs_}, {"wsock32#17", recvfrom_},
    {"wsock32#18", select_}, {"wsock32#20", sendto_}, {"wsock32#21", setsockopt_}, {"wsock32#23", socket_}, {"wsock32#52", gethostbyname_},
    {"wsock32#57", gethostname_}, {"wsock32#111", WSAGetLastError_}, {"wsock32#115", WSAStartup_}, {"wsock32#116", WSACleanup_},
    {"dplayx#1", dplay1}, {"dplayx#2", dplay2}, {"dplayx#4", dplay4},
};
const ShimTable misc_shims = {misc_list, (int)(sizeof misc_list / sizeof *misc_list)};
