//! A program on a hidden console of its own, the Windows counterpart of the
//! Unix pseudo-terminal.
//!
//! `terminal` starts this helper again as `console-inner` in a new, hidden
//! console, with the request in a file. The inner helper starts the program
//! with its input read from that console, types the input as key presses, and
//! checks that the console mode is put back once the program has exited. It
//! writes the outcome to a second file, which the outer helper prints.

use crate::{outcome_json, parse_request, sleep_seconds, Outcome, Request};
use std::io::Read;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows_sys::core::BOOL;
use windows_sys::Win32::Foundation::{
    CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::Console::{
    GenerateConsoleCtrlEvent, GetConsoleMode, SetConsoleCtrlHandler, WriteConsoleInputW,
    CTRL_BREAK_EVENT, CTRL_C_EVENT, INPUT_RECORD, KEY_EVENT,
};
use windows_sys::Win32::System::Threading::{
    CreateProcessW, GetExitCodeProcess, TerminateProcess, WaitForSingleObject, CREATE_NEW_CONSOLE,
    CREATE_NEW_PROCESS_GROUP, PROCESS_INFORMATION, STARTF_USESHOWWINDOW, STARTUPINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::SW_HIDE;

/// Exits with a full 32-bit Windows exit code.
pub fn exit_with(code: i32) -> ExitCode {
    std::process::exit(code)
}

fn wide(text: &std::ffi::OsStr) -> Vec<u16> {
    text.encode_wide().chain(std::iter::once(0)).collect()
}

fn os_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

/// A folder for the request and the result, removed when dropped.
struct Exchange(PathBuf);

impl Drop for Exchange {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Runs the request in a new, hidden console and returns the JSON it wrote.
pub fn run(request: &Request) -> Result<String, String> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let exchange =
        Exchange(std::env::temp_dir().join(format!("test-helper-{}-{nanos}", std::process::id())));
    std::fs::create_dir(&exchange.0)
        .map_err(|error| format!("could not create {}: {error}", exchange.0.display()))?;
    let request_file = exchange.0.join("request");
    let result_file = exchange.0.join("result.json");
    std::fs::write(&request_file, encode_request(request))
        .map_err(|error| format!("could not write the request: {error}"))?;
    let exe =
        std::env::current_exe().map_err(|error| format!("could not find this helper: {error}"))?;
    // The paths hold no quotes, and none of them ends in a backslash.
    let mut command_line = wide(
        format!(
            "\"{}\" console-inner \"{}\" \"{}\"",
            exe.display(),
            request_file.display(),
            result_file.display()
        )
        .as_ref(),
    );
    let exe_wide = wide(exe.as_os_str());
    let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
    startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE as u16;
    let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let created = unsafe {
        CreateProcessW(
            exe_wide.as_ptr(),
            command_line.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NEW_CONSOLE,
            std::ptr::null(),
            std::ptr::null(),
            &startup,
            &mut process,
        )
    };
    if created == 0 {
        return Err(os_error("could not start the console runner"));
    }
    let limit = ((request.timeout + 10.0) * 1000.0) as u32;
    let waited = unsafe { WaitForSingleObject(process.hProcess, limit) };
    let mut code: u32 = 0;
    unsafe {
        if waited == WAIT_TIMEOUT {
            TerminateProcess(process.hProcess, 1);
        }
        GetExitCodeProcess(process.hProcess, &mut code);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    if waited == WAIT_TIMEOUT {
        return Err(format!(
            "Console runner timed out after {}s",
            request.timeout + 10.0
        ));
    }
    let text = std::fs::read_to_string(&result_file).map_err(|error| {
        format!("Console runner failed with exit code {code} and no result: {error}")
    })?;
    Ok(text)
}

/// The request as the inner helper reads it: the arguments of `terminal`,
/// each ended by a NUL.
fn encode_request(request: &Request) -> Vec<u8> {
    let mut words = vec![
        "--timeout".to_string(),
        request.timeout.to_string(),
        "--input-delay".to_string(),
        request.input_delay.to_string(),
        "--stdin-hex".to_string(),
        request
            .stdin
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    ];
    if request.await_raw_mode {
        words.push("--await-raw-mode".into());
    }
    if let Some(text) = &request.await_output {
        words.extend(["--await-output".to_string(), text.clone()]);
    }
    if let Some(name) = &request.send_signal {
        words.extend(["--send-signal".to_string(), name.clone()]);
    }
    words.push("--".into());
    words.extend(request.args.iter().cloned());
    words
        .iter()
        .flat_map(|word| word.bytes().chain(std::iter::once(0)))
        .collect()
}

fn decode_request(bytes: &[u8]) -> Result<Request, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "the request is not UTF-8".to_string())?;
    let words: Vec<String> = text.split_terminator('\0').map(str::to_string).collect();
    parse_request(&words)
}

/// `console-inner REQUEST RESULT`, in the new console.
pub fn inner(args: &[String]) -> ExitCode {
    let [request_file, result_file] = args else {
        return ExitCode::from(2);
    };
    let outcome = std::fs::read(request_file)
        .map_err(|error| format!("could not read the request: {error}"))
        .and_then(|bytes| decode_request(&bytes))
        .and_then(|request| run_here(&request));
    // The caller cannot see this console, so every failure goes in the result.
    match std::fs::write(Path::new(result_file), outcome_json(&outcome)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}

struct Console(HANDLE);

impl Drop for Console {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

impl Console {
    fn open() -> Result<Console, String> {
        let name = wide("CONIN$".as_ref());
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(os_error("CONIN$"));
        }
        Ok(Console(handle))
    }

    fn mode(&self) -> Result<u32, String> {
        let mut mode = 0;
        if unsafe { GetConsoleMode(self.0, &mut mode) } == 0 {
            return Err(os_error("GetConsoleMode"));
        }
        Ok(mode)
    }

    fn press_key(&self, unit: u16) -> Result<(), String> {
        let mut records: [INPUT_RECORD; 2] = unsafe { std::mem::zeroed() };
        for (record, key_down) in records.iter_mut().zip([1, 0]) {
            record.EventType = KEY_EVENT as u16;
            record.Event.KeyEvent.bKeyDown = key_down;
            record.Event.KeyEvent.wRepeatCount = 1;
            record.Event.KeyEvent.uChar.UnicodeChar = unit;
        }
        let mut written = 0;
        if unsafe { WriteConsoleInputW(self.0, records.as_ptr(), 2, &mut written) } == 0 {
            return Err(os_error("WriteConsoleInputW"));
        }
        Ok(())
    }
}

/// Ignores Ctrl+C in this helper. CTRL_C_EVENT goes to every process on the
/// console, and the program re-enables it for itself when it catches it.
unsafe extern "system" fn ignore_ctrl_c(event: u32) -> BOOL {
    (event == CTRL_C_EVENT) as BOOL
}

fn has_exited(child: &mut Child) -> bool {
    !matches!(child.try_wait(), Ok(None))
}

fn run_here(request: &Request) -> Outcome {
    let deadline = Instant::now() + Duration::from_secs_f64(request.timeout);
    let console = Console::open()?;
    if unsafe { SetConsoleCtrlHandler(Some(ignore_ctrl_c), 1) } == 0 {
        return Err(os_error("SetConsoleCtrlHandler"));
    }
    let initial_mode = console.mode()?;
    let input = std::fs::OpenOptions::new()
        .read(true)
        .open("CONIN$")
        .map_err(|error| format!("CONIN$: {error}"))?;
    let (mut reader, writer) = std::io::pipe().map_err(|error| format!("pipe: {error}"))?;
    let writer_copy = writer
        .try_clone()
        .map_err(|error| format!("pipe: {error}"))?;
    let mut command = Command::new(&request.args[0]);
    command
        .args(&request.args[1..])
        .stdin(Stdio::from(input))
        .stdout(writer)
        .stderr(writer_copy)
        // Its own group, so a console event can be sent to it alone.
        .creation_flags(CREATE_NEW_PROCESS_GROUP);
    let mut child = command
        .spawn()
        .map_err(|error| format!("could not start {}: {error}", request.args[0]))?;
    // The pipe ends once the program and its children have closed it.
    drop(command);
    let output = Arc::new(Mutex::new(Vec::new()));
    let collected = Arc::clone(&output);
    let reading = std::thread::spawn(move || {
        // In chunks, so await_output sees what has been printed so far.
        let mut buffer = vec![0u8; 65536];
        while let Ok(count) = reader.read(&mut buffer) {
            if count == 0 {
                break;
            }
            collected
                .lock()
                .unwrap()
                .extend_from_slice(&buffer[..count]);
        }
    });
    let result = drive(
        request,
        &console,
        initial_mode,
        &mut child,
        deadline,
        &output,
    );
    if !has_exited(&mut child) {
        let _ = child.kill();
        let _ = child.wait();
    }
    let (exit_code, ()) = result?;
    let _ = reading.join();
    if console.mode()? != initial_mode {
        return Err("Terminal mode was not restored".into());
    }
    let bytes = output.lock().unwrap().clone();
    Ok((exit_code, String::from_utf8_lossy(&bytes).into_owned()))
}

fn drive(
    request: &Request,
    console: &Console,
    initial_mode: u32,
    child: &mut Child,
    deadline: Instant,
    output: &Arc<Mutex<Vec<u8>>>,
) -> Result<(i64, ()), String> {
    if request.await_raw_mode {
        while console.mode()? == initial_mode {
            if has_exited(child) || Instant::now() >= deadline {
                return Err("Terminal never changed mode".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    } else if let Some(expected) = &request.await_output {
        loop {
            let printed =
                String::from_utf8_lossy(&output.lock().unwrap()).contains(expected.as_str());
            if printed {
                break;
            }
            if has_exited(child) || Instant::now() >= deadline {
                return Err(format!("Never printed {expected:?}"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    } else {
        sleep_seconds(0.25);
    }
    let typed = String::from_utf8_lossy(&request.stdin).into_owned();
    for character in typed.chars() {
        let mut units = [0u16; 2];
        for unit in character.encode_utf16(&mut units) {
            console.press_key(*unit)?;
        }
        sleep_seconds(request.input_delay);
    }
    match request.send_signal.as_deref() {
        None => {}
        Some("SIGINT") => {
            if unsafe { GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) } == 0 {
                return Err(os_error("GenerateConsoleCtrlEvent"));
            }
        }
        // Windows has no signals. Ctrl+Break stands in for the others.
        Some(_) => {
            if unsafe { GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child.id()) } == 0 {
                return Err(os_error("GenerateConsoleCtrlEvent"));
            }
        }
    }
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Ok((status.code().unwrap_or(1) as i64, ()));
        }
        if Instant::now() >= deadline {
            return Err(format!("Timed out after {}s", request.timeout));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
