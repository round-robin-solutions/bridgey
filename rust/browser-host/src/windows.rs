//! Windows: the app's named pipe, `\\.\pipe\in.roundrobin.bridgey.browser.<SID>`. The app creates it for this user
//! only; the helper still checks that the process serving it runs as this user before writing anything, so a pipe
//! another account created first under the same name never gets the address.

use bridgey_browser_host::{pipe_name, read_line, TransportError, MAX_REPLY};
use std::ffi::c_void;
use std::fs::File;
use std::io::Write;
use std::os::windows::io::{FromRawHandle, RawHandle};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_PIPE_BUSY, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows_sys::Win32::Security::{EqualSid, GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows_sys::Win32::Storage::FileSystem::{CreateFileW, OPEN_EXISTING, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT};
use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION};

/// Tests point the helper at another pipe (a full `\\.\pipe\...` name).
const PIPE_OVERRIDE: &str = "BRIDGEY_BROWSER_PIPE";

pub fn ask(line: &[u8]) -> Result<Vec<u8>, TransportError> {
    let me = TokenSid::of_process(unsafe { GetCurrentProcess() }).ok_or(TransportError::NotRunning)?;
    let name = match std::env::var(PIPE_OVERRIDE) {
        Ok(name) if name.starts_with(r"\\.\pipe\") => name,
        _ => pipe_name(&me.to_string().ok_or(TransportError::NotRunning)?).ok_or(TransportError::NotRunning)?,
    };
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let handle = open(&wide)?;
    // SAFETY: `handle` is a pipe handle we own; File takes ownership and closes it.
    let mut pipe = unsafe { File::from_raw_handle(handle as RawHandle) };
    let mut server_pid = 0u32;
    // SAFETY: valid pipe handle and out pointer.
    if unsafe { GetNamedPipeServerProcessId(handle, &mut server_pid) } == 0 {
        return Err(TransportError::Unsafe);
    }
    let same_user = {
        // SAFETY: OpenProcess returns null on failure; the handle is closed below.
        let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, server_pid) };
        if process.is_null() {
            false
        } else {
            let server = TokenSid::of_process(process);
            unsafe { CloseHandle(process) };
            server.is_some_and(|server| server.equals(&me))
        }
    };
    if !same_user {
        return Err(TransportError::Unsafe);
    }
    pipe.write_all(line).map_err(|_| TransportError::NoAnswer)?;
    read_line(&mut pipe, MAX_REPLY)
}

fn open(name: &[u16]) -> Result<HANDLE, TransportError> {
    for _ in 0..3 {
        // SAFETY: `name` is NUL-terminated; identification level means the app can see who we are but never act as us.
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                std::ptr::null(),
                OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                std::ptr::null_mut(),
            )
        };
        if handle != INVALID_HANDLE_VALUE {
            return Ok(handle);
        }
        if unsafe { GetLastError() } != ERROR_PIPE_BUSY || unsafe { WaitNamedPipeW(name.as_ptr(), 2000) } == 0 {
            return Err(TransportError::NotRunning);
        }
    }
    Err(TransportError::NotRunning)
}

/// A process token's user SID, copied out of TOKEN_USER.
struct TokenSid {
    buffer: Vec<u64>,
}

impl TokenSid {
    fn of_process(process: HANDLE) -> Option<TokenSid> {
        let mut token: HANDLE = std::ptr::null_mut();
        // SAFETY: valid process handle and out pointer; the token is closed below.
        if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
            return None;
        }
        let mut needed = 0u32;
        unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
        let mut buffer = vec![0u64; (needed as usize).div_ceil(8).max(1)];
        let ok = unsafe { GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), (buffer.len() * 8) as u32, &mut needed) };
        unsafe { CloseHandle(token) };
        (ok != 0).then_some(TokenSid { buffer })
    }

    fn sid(&self) -> *mut c_void {
        // SAFETY: the buffer holds a TOKEN_USER written by GetTokenInformation and is 8-byte aligned.
        unsafe { (*(self.buffer.as_ptr() as *const TOKEN_USER)).User.Sid }
    }

    fn equals(&self, other: &TokenSid) -> bool {
        // SAFETY: both SIDs point into live TOKEN_USER buffers.
        unsafe { EqualSid(self.sid(), other.sid()) != 0 }
    }

    fn to_string(&self) -> Option<String> {
        let mut text: *mut u16 = std::ptr::null_mut();
        // SAFETY: valid SID; the string is freed with LocalFree.
        if unsafe { ConvertSidToStringSidW(self.sid(), &mut text) } == 0 || text.is_null() {
            return None;
        }
        let mut length = 0;
        while unsafe { *text.add(length) } != 0 {
            length += 1;
        }
        let value = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).ok();
        unsafe { LocalFree(text.cast()) };
        value
    }
}
