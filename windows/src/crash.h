// Local crash capture for the Windows apprt: an unhandled-exception filter
// that writes a minidump beside the log
// (%LOCALAPPDATA%\Boo\logs\boo-crash.dmp), then lets Windows Error Reporting
// proceed. Nothing is ever uploaded (docs/logging-and-crash-reporting.md).
// The POSIX frontends use the core's boo_crash_init instead.
#ifndef BOO_CRASH_H
#define BOO_CRASH_H

void boo_crash_install(void);

#endif // BOO_CRASH_H
