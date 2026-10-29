//! File responses from roots declared when a server starts, ported from
//! basic-webserver's file server without its compression and metrics.
//!
//! A path is opened one component at a time below the root, never following a
//! link, and a component that starts with a dot is refused, so a response can
//! only ever name a file inside its root. The host streams the file on a thread
//! of its own and answers conditional and single-range requests.

use crate::server::{empty_body, full_body, ServerResponse};
use bytes::Bytes;
use cap_primitives::fs::{open, open_ambient_dir, open_dir_nofollow, FollowSymlinks, OpenOptions};
use http_body_util::BodyExt;
use hyper::body::{Body, Frame, SizeHint};
use hyper::header::{
    ACCEPT_RANGES, ALLOW, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE, ETAG,
    IF_MATCH, IF_MODIFIED_SINCE, IF_NONE_MATCH, IF_RANGE, IF_UNMODIFIED_SINCE, LAST_MODIFIED,
    RANGE,
};
use hyper::{HeaderMap, Method, StatusCode};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, oneshot, OwnedSemaphorePermit, Semaphore};

const MAX_FILE_ROOTS: usize = 64;
const MAX_RELATIVE_PATH_BYTES: usize = 4 * 1024;
const MAX_CONCURRENT_TRANSFERS: usize = 256;
const CHUNK_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CachePolicy {
    NoStore,
    Revalidate,
    PrivateFor(u32),
    PublicFor(u32),
}

impl CachePolicy {
    /// `None` for 255, which keeps the root's own policy.
    pub(crate) fn from_abi(tag: u8, max_age_seconds: u32) -> Result<Option<Self>, String> {
        match tag {
            0 => Ok(Some(Self::NoStore)),
            1 => Ok(Some(Self::Revalidate)),
            2 => Ok(Some(Self::PrivateFor(max_age_seconds))),
            3 => Ok(Some(Self::PublicFor(max_age_seconds))),
            255 => Ok(None),
            _ => Err(format!("invalid file cache policy {tag}")),
        }
    }

    fn header_value(self) -> String {
        match self {
            Self::NoStore => "no-store".to_owned(),
            Self::Revalidate => "no-cache".to_owned(),
            Self::PrivateFor(seconds) => format!("private, max-age={seconds}"),
            Self::PublicFor(seconds) => format!("public, max-age={seconds}"),
        }
    }
}

#[derive(Debug)]
pub(crate) struct FileRootSpec {
    pub(crate) name: String,
    pub(crate) path: PathBuf,
    pub(crate) cache: CachePolicy,
}

/// Why the roots could not be opened.
#[derive(Debug)]
pub(crate) enum RootError {
    Config(String),
    Root(String, io::Error),
}

#[derive(Clone, Debug)]
pub(crate) struct FilePlan {
    pub(crate) root: String,
    pub(crate) relative: String,
    pub(crate) cache: Option<CachePolicy>,
}

#[derive(Debug)]
struct FileRoot {
    handle: File,
    cache: CachePolicy,
}

#[derive(Clone, Debug)]
pub(crate) struct FileService {
    roots: Arc<BTreeMap<String, Arc<FileRoot>>>,
    transfers: Arc<Semaphore>,
}

impl FileService {
    pub(crate) fn activate(root_specs: Vec<FileRootSpec>) -> Result<Self, RootError> {
        if root_specs.len() > MAX_FILE_ROOTS {
            return Err(RootError::Config(format!(
                "at most {MAX_FILE_ROOTS} file roots may be declared"
            )));
        }
        let mut roots = BTreeMap::new();
        for spec in root_specs {
            validate_root_name(&spec.name).map_err(RootError::Config)?;
            if roots.contains_key(&spec.name) {
                return Err(RootError::Config(format!(
                    "two file roots are named {:?}",
                    spec.name
                )));
            }
            let handle = open_ambient_dir(&spec.path, cap_primitives::ambient_authority())
                .map_err(|error| RootError::Root(spec.name.clone(), error))?;
            let metadata = handle
                .metadata()
                .map_err(|error| RootError::Root(spec.name.clone(), error))?;
            if !metadata.is_dir() {
                return Err(RootError::Root(
                    spec.name,
                    io::Error::new(io::ErrorKind::NotADirectory, "not a directory"),
                ));
            }
            roots.insert(
                spec.name,
                Arc::new(FileRoot {
                    handle,
                    cache: spec.cache,
                }),
            );
        }
        Ok(Self {
            roots: Arc::new(roots),
            transfers: Arc::new(Semaphore::new(MAX_CONCURRENT_TRANSFERS)),
        })
    }

    pub(crate) async fn serve(
        &self,
        plan: FilePlan,
        method: &Method,
        headers: &HeaderMap,
    ) -> ServerResponse {
        if method != Method::GET && method != Method::HEAD {
            return simple_response(
                StatusCode::METHOD_NOT_ALLOWED,
                &[(ALLOW, "GET, HEAD")],
                Bytes::from_static(b"Method Not Allowed"),
            );
        }
        let Some(root) = self.roots.get(&plan.root).map(Arc::clone) else {
            eprintln!(
                "A handler answered with a file from {:?}, which is not one of the server's roots",
                plan.root
            );
            return simple_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &[],
                Bytes::from_static(b"Internal Server Error"),
            );
        };
        let Ok(permit) = Arc::clone(&self.transfers).try_acquire_owned() else {
            return simple_response(
                StatusCode::SERVICE_UNAVAILABLE,
                &[],
                Bytes::from_static(b"Too many file transfers"),
            );
        };
        let method = method.clone();
        let headers = headers.clone();
        let (prepared_sender, prepared_receiver) = oneshot::channel();
        let spawned = std::thread::Builder::new()
            .name("joy-cli-file".to_owned())
            .spawn(move || {
                prepare_and_stream(root, plan, method, headers, permit, prepared_sender)
            });
        if let Err(error) = spawned {
            return simple_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &[],
                Bytes::from(format!("Failed to start file transfer: {error}")),
            );
        }
        match prepared_receiver.await {
            Ok(prepared) => prepared.into_response(),
            Err(_) => simple_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &[],
                Bytes::from_static(b"File transfer failed before producing a response"),
            ),
        }
    }
}

struct FileBody {
    receiver: mpsc::Receiver<io::Result<Bytes>>,
    permit: Option<OwnedSemaphorePermit>,
    remaining: u64,
}

impl Body for FileBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        match self.receiver.poll_recv(context) {
            Poll::Ready(Some(Ok(bytes))) => {
                self.remaining = self.remaining.saturating_sub(bytes.len() as u64);
                Poll::Ready(Some(Ok(Frame::data(bytes))))
            }
            Poll::Ready(Some(Err(error))) => {
                self.permit.take();
                Poll::Ready(Some(Err(error)))
            }
            Poll::Ready(None) => {
                self.permit.take();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }

    fn is_end_stream(&self) -> bool {
        self.remaining == 0
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.remaining)
    }
}

struct Prepared {
    status: StatusCode,
    headers: HeaderMap,
    body: Option<FileBody>,
}

impl Prepared {
    fn into_response(self) -> ServerResponse {
        let body = self
            .body
            .map_or_else(empty_body, |body| body.boxed_unsync());
        let mut response = hyper::Response::new(body);
        *response.status_mut() = self.status;
        *response.headers_mut() = self.headers;
        response
    }

    fn without_body(status: StatusCode, headers: HeaderMap) -> Self {
        Self {
            status,
            headers,
            body: None,
        }
    }
}

fn prepare_and_stream(
    root: Arc<FileRoot>,
    plan: FilePlan,
    method: Method,
    request_headers: HeaderMap,
    permit: OwnedSemaphorePermit,
    prepared_sender: oneshot::Sender<Prepared>,
) {
    let Ok(segments) = decode_uri_relative_path(&plan.relative) else {
        let _ = prepared_sender.send(not_found());
        return;
    };
    let Ok(mut file) = open_relative_file(&root.handle, &segments) else {
        let _ = prepared_sender.send(not_found());
        return;
    };
    let metadata = match file.metadata() {
        Ok(metadata) if metadata.is_file() => metadata,
        _ => {
            let _ = prepared_sender.send(not_found());
            return;
        }
    };
    let length = metadata.len();
    let modified = metadata.modified().ok();
    let etag = weak_etag(length, modified);
    let cache = plan.cache.unwrap_or(root.cache);
    let mut response_headers = representation_headers(
        segments
            .last()
            .expect("validated relative paths contain a final component"),
        length,
        modified,
        &etag,
        cache,
    );

    if let Some(status) = precondition_status(&request_headers, &etag, modified, &method) {
        if status == StatusCode::NOT_MODIFIED {
            response_headers.remove(CONTENT_LENGTH);
            response_headers.remove(CONTENT_TYPE);
        } else {
            response_headers.insert(CONTENT_LENGTH, hyper::header::HeaderValue::from_static("0"));
        }
        let _ = prepared_sender.send(Prepared::without_body(status, response_headers));
        return;
    }

    let selected_range = if if_range_allows(&request_headers, &etag, modified) {
        parse_range(&request_headers, length)
    } else {
        RangeSelection::Ignore
    };
    let (status, start, response_length) = match selected_range {
        RangeSelection::Ignore => (StatusCode::OK, 0, length),
        RangeSelection::Unsatisfiable => {
            response_headers.insert(
                CONTENT_RANGE,
                format!("bytes */{length}")
                    .parse()
                    .expect("content range generated by host is valid"),
            );
            response_headers.insert(CONTENT_LENGTH, hyper::header::HeaderValue::from_static("0"));
            let _ = prepared_sender.send(Prepared::without_body(
                StatusCode::RANGE_NOT_SATISFIABLE,
                response_headers,
            ));
            return;
        }
        RangeSelection::Range { start, end } => {
            response_headers.insert(
                CONTENT_RANGE,
                format!("bytes {start}-{end}/{length}")
                    .parse()
                    .expect("content range generated by host is valid"),
            );
            (StatusCode::PARTIAL_CONTENT, start, end - start + 1)
        }
    };
    response_headers.insert(
        CONTENT_LENGTH,
        response_length
            .to_string()
            .parse()
            .expect("content length generated by host is valid"),
    );

    if method == Method::HEAD || response_length == 0 {
        let _ = prepared_sender.send(Prepared::without_body(status, response_headers));
        return;
    }
    if file.seek(SeekFrom::Start(start)).is_err() {
        let _ = prepared_sender.send(not_found());
        return;
    }

    let (body_sender, body_receiver) = mpsc::channel(1);
    let body = FileBody {
        receiver: body_receiver,
        permit: Some(permit),
        remaining: response_length,
    };
    if prepared_sender
        .send(Prepared {
            status,
            headers: response_headers,
            body: Some(body),
        })
        .is_err()
    {
        return;
    }
    if let Err(error) = copy_file(&mut file, response_length, |bytes| {
        body_sender
            .blocking_send(Ok(Bytes::copy_from_slice(bytes)))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "response body dropped"))
    }) {
        let _ = body_sender.blocking_send(Err(error));
    }
}

fn copy_file(
    file: &mut File,
    length: u64,
    mut consume: impl FnMut(&[u8]) -> io::Result<()>,
) -> io::Result<()> {
    let mut remaining = length;
    let mut buffer = vec![0; CHUNK_BYTES];
    while remaining > 0 {
        let next = usize::try_from(remaining.min(CHUNK_BYTES as u64))
            .expect("bounded file chunk fits usize");
        file.read_exact(&mut buffer[..next])?;
        remaining -= next as u64;
        consume(&buffer[..next])?;
    }
    Ok(())
}

fn simple_response(
    status: StatusCode,
    headers: &[(hyper::header::HeaderName, &'static str)],
    body: Bytes,
) -> ServerResponse {
    let mut response = hyper::Response::new(full_body(body));
    *response.status_mut() = status;
    for (name, value) in headers {
        response
            .headers_mut()
            .insert(name, hyper::header::HeaderValue::from_static(value));
    }
    response
}

fn not_found() -> Prepared {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_LENGTH, hyper::header::HeaderValue::from_static("0"));
    Prepared::without_body(StatusCode::NOT_FOUND, headers)
}

pub(crate) fn validate_root_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(format!(
            "file root name {name:?} must have 1 to 64 ASCII letters, digits, '-' or '_'"
        ));
    }
    Ok(())
}

/// A path as it appears in a URL: a leading slash and a query are ignored, and
/// percent escapes are decoded, except for escaped separators.
fn decode_uri_relative_path(relative: &str) -> Result<Vec<String>, String> {
    let relative = relative.split('?').next().unwrap_or("");
    let relative = relative.strip_prefix('/').unwrap_or(relative);
    if relative.is_empty() || relative.len() > MAX_RELATIVE_PATH_BYTES {
        return Err("relative file path is empty or too long".to_owned());
    }
    relative
        .split('/')
        .map(|segment| {
            if segment.is_empty() || segment.as_bytes().contains(&b'\\') {
                return Err("invalid URI path component".to_owned());
            }
            let bytes = percent_decode(segment.as_bytes())?;
            let decoded =
                String::from_utf8(bytes).map_err(|_| "URI path is not valid UTF-8".to_owned())?;
            validate_decoded_segment(&decoded)
        })
        .collect()
}

fn percent_decode(input: &[u8]) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if input[index] != b'%' {
            output.push(input[index]);
            index += 1;
            continue;
        }
        if index + 2 >= input.len() {
            return Err("truncated percent escape".to_owned());
        }
        let high =
            hex_value(input[index + 1]).ok_or_else(|| "invalid percent escape".to_owned())?;
        let low = hex_value(input[index + 2]).ok_or_else(|| "invalid percent escape".to_owned())?;
        let byte = high * 16 + low;
        if byte == b'/' || byte == b'\\' {
            return Err("encoded path separator".to_owned());
        }
        output.push(byte);
        index += 3;
    }
    Ok(output)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn validate_decoded_segment(segment: &str) -> Result<String, String> {
    if segment.is_empty()
        || segment == "."
        || segment == ".."
        || segment.starts_with('.')
        || segment
            .bytes()
            .any(|byte| byte == 0 || byte == b'\\' || byte == b':' || byte == b'/')
    {
        return Err("unsafe relative file component".to_owned());
    }
    Ok(segment.to_owned())
}

fn open_relative_file(root: &File, segments: &[String]) -> io::Result<File> {
    let (last, parents) = segments
        .split_last()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty relative path"))?;
    let mut current = root.try_clone()?;
    for parent in parents {
        current = open_dir_nofollow(&current, Path::new(parent))?;
    }
    let mut options = OpenOptions::new();
    options.read(true)._cap_fs_ext_follow(FollowSymlinks::No);
    open(&current, Path::new(last), &options)
}

fn representation_headers(
    relative: &str,
    length: u64,
    modified: Option<SystemTime>,
    etag: &str,
    cache: CachePolicy,
) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        ACCEPT_RANGES,
        hyper::header::HeaderValue::from_static("bytes"),
    );
    headers.insert(
        CACHE_CONTROL,
        cache
            .header_value()
            .parse()
            .expect("typed cache policy generates a valid header"),
    );
    headers.insert(
        CONTENT_LENGTH,
        length
            .to_string()
            .parse()
            .expect("file length generates a valid header"),
    );
    headers.insert(
        CONTENT_TYPE,
        content_type(relative)
            .parse()
            .expect("static content type is a valid header"),
    );
    headers.insert(
        ETAG,
        etag.parse()
            .expect("host-generated ETag is a valid header value"),
    );
    if let Some(modified) = modified {
        headers.insert(
            LAST_MODIFIED,
            httpdate::fmt_http_date(modified)
                .parse()
                .expect("HTTP date is a valid header"),
        );
    }
    headers
}

fn content_type(relative: &str) -> &'static str {
    let extension = relative
        .rsplit('/')
        .next()
        .and_then(|name| name.rsplit_once('.').map(|(_, extension)| extension))
        .unwrap_or("")
        .to_ascii_lowercase();
    match extension.as_str() {
        "avif" => "image/avif",
        "css" => "text/css; charset=utf-8",
        "csv" => "text/csv; charset=utf-8",
        "gif" => "image/gif",
        "htm" | "html" => "text/html; charset=utf-8",
        "ico" => "image/x-icon",
        "jpeg" | "jpg" => "image/jpeg",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json",
        "map" => "application/json",
        "mp4" => "video/mp4",
        "otf" => "font/otf",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "ttf" => "font/ttf",
        "txt" => "text/plain; charset=utf-8",
        "wasm" => "application/wasm",
        "webm" => "video/webm",
        "webmanifest" => "application/manifest+json",
        "webp" => "image/webp",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "xml" => "application/xml",
        _ => "application/octet-stream",
    }
}

fn weak_etag(length: u64, modified: Option<SystemTime>) -> String {
    let nanos = modified
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_nanos());
    format!("W/\"{length:x}-{nanos:x}\"")
}

fn precondition_status(
    headers: &HeaderMap,
    etag: &str,
    modified: Option<SystemTime>,
    method: &Method,
) -> Option<StatusCode> {
    if headers.contains_key(IF_MATCH) {
        if !etag_condition_matches(headers, IF_MATCH, etag, false) {
            return Some(StatusCode::PRECONDITION_FAILED);
        }
    } else if let (Some(value), Some(modified)) = (headers.get(IF_UNMODIFIED_SINCE), modified) {
        if parse_http_date(value).is_some_and(|date| is_later(modified, date)) {
            return Some(StatusCode::PRECONDITION_FAILED);
        }
    }

    if headers.contains_key(IF_NONE_MATCH) {
        if etag_condition_matches(headers, IF_NONE_MATCH, etag, true) {
            return Some(if method == Method::GET || method == Method::HEAD {
                StatusCode::NOT_MODIFIED
            } else {
                StatusCode::PRECONDITION_FAILED
            });
        }
    } else if method == Method::GET || method == Method::HEAD {
        if let (Some(value), Some(modified)) = (headers.get(IF_MODIFIED_SINCE), modified) {
            if parse_http_date(value).is_some_and(|date| !is_later(modified, date)) {
                return Some(StatusCode::NOT_MODIFIED);
            }
        }
    }
    None
}

fn etag_condition_matches(
    headers: &HeaderMap,
    name: hyper::header::HeaderName,
    current: &str,
    weak: bool,
) -> bool {
    headers.get_all(name).iter().any(|value| {
        value.to_str().ok().is_some_and(|raw| {
            raw.split(',').any(|candidate| {
                let candidate = candidate.trim();
                candidate == "*"
                    || if weak {
                        strip_weak(candidate) == strip_weak(current)
                            && candidate.ends_with('"')
                            && candidate.contains('"')
                    } else {
                        !candidate.starts_with("W/") && candidate == current
                    }
            })
        })
    })
}

fn strip_weak(value: &str) -> &str {
    value.strip_prefix("W/").unwrap_or(value)
}

fn parse_http_date(value: &hyper::header::HeaderValue) -> Option<SystemTime> {
    value
        .to_str()
        .ok()
        .and_then(|raw| httpdate::parse_http_date(raw).ok())
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs())
}

fn is_later(left: SystemTime, right: SystemTime) -> bool {
    unix_seconds(left) > unix_seconds(right)
}

fn if_range_allows(headers: &HeaderMap, etag: &str, modified: Option<SystemTime>) -> bool {
    let Some(value) = headers.get(IF_RANGE) else {
        return true;
    };
    let Ok(raw) = value.to_str() else {
        return false;
    };
    if raw.starts_with('"') || raw.starts_with("W/") {
        return !raw.starts_with("W/") && !etag.starts_with("W/") && raw == etag;
    }
    match (httpdate::parse_http_date(raw).ok(), modified) {
        (Some(date), Some(modified)) => !is_later(modified, date),
        _ => false,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RangeSelection {
    Ignore,
    Unsatisfiable,
    Range { start: u64, end: u64 },
}

fn parse_range(headers: &HeaderMap, length: u64) -> RangeSelection {
    let mut values = headers.get_all(RANGE).iter();
    let Some(value) = values.next() else {
        return RangeSelection::Ignore;
    };
    if values.next().is_some() {
        return RangeSelection::Ignore;
    }
    let Some(raw) = value.to_str().ok() else {
        return RangeSelection::Ignore;
    };
    let Some(spec) = raw.strip_prefix("bytes=") else {
        return RangeSelection::Ignore;
    };
    if spec.contains(',') {
        return RangeSelection::Ignore;
    }
    let Some((first, last)) = spec.split_once('-') else {
        return RangeSelection::Ignore;
    };
    if first.is_empty() {
        let Ok(suffix) = last.parse::<u64>() else {
            return RangeSelection::Ignore;
        };
        if suffix == 0 || length == 0 {
            return RangeSelection::Unsatisfiable;
        }
        let start = length.saturating_sub(suffix);
        return RangeSelection::Range {
            start,
            end: length - 1,
        };
    }
    let Ok(start) = first.parse::<u64>() else {
        return RangeSelection::Ignore;
    };
    if start >= length {
        return RangeSelection::Unsatisfiable;
    }
    if last.is_empty() {
        return RangeSelection::Range {
            start,
            end: length - 1,
        };
    }
    let Ok(end) = last.parse::<u64>() else {
        return RangeSelection::Ignore;
    };
    if start > end {
        return RangeSelection::Ignore;
    }
    RangeSelection::Range {
        start,
        end: end.min(length - 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn service(root: &Path) -> FileService {
        FileService::activate(vec![FileRootSpec {
            name: "root".to_owned(),
            path: root.to_path_buf(),
            cache: CachePolicy::Revalidate,
        }])
        .unwrap()
    }

    fn plan(relative: &str) -> FilePlan {
        FilePlan {
            root: "root".to_owned(),
            relative: relative.to_owned(),
            cache: None,
        }
    }

    #[test]
    fn root_activation_rejects_duplicates_and_missing_directories() {
        let temp = tempfile::tempdir().unwrap();
        let duplicate = FileService::activate(vec![
            FileRootSpec {
                name: "root".to_owned(),
                path: temp.path().to_path_buf(),
                cache: CachePolicy::Revalidate,
            },
            FileRootSpec {
                name: "root".to_owned(),
                path: temp.path().to_path_buf(),
                cache: CachePolicy::NoStore,
            },
        ]);
        assert!(
            matches!(duplicate, Err(RootError::Config(message)) if message.contains("two file roots"))
        );

        let absent = FileService::activate(vec![FileRootSpec {
            name: "absent".to_owned(),
            path: temp.path().join("does-not-exist"),
            cache: CachePolicy::Revalidate,
        }]);
        assert!(
            matches!(absent, Err(RootError::Root(name, error)) if name == "absent" && error.kind() == io::ErrorKind::NotFound)
        );
    }

    #[test]
    fn uri_path_validation_rejects_traversal_and_encoded_separators() {
        for invalid in [
            "",
            "/",
            ".",
            "..",
            "%2e%2e",
            ".hidden",
            "dir/.hidden",
            "dir//file",
            "dir/%2Ffile",
            "dir/%5cfile",
            "C:%5csecret",
            "dir/%00file",
            "dir/%ff",
            "dir/%",
        ] {
            assert!(
                decode_uri_relative_path(invalid).is_err(),
                "{invalid:?} should be rejected"
            );
        }
        assert_eq!(
            decode_uri_relative_path("dir/a%20file.txt").unwrap(),
            ["dir", "a file.txt"]
        );
        assert_eq!(
            decode_uri_relative_path("/app/app.wasm?joy=3").unwrap(),
            ["app", "app.wasm"]
        );
        assert!(decode_uri_relative_path(&"x".repeat(MAX_RELATIVE_PATH_BYTES + 1)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn rooted_open_rejects_symlinks_in_every_component() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let (root, outside) = (root.path(), outside.path());
        fs::write(outside.join("secret.txt"), b"secret").unwrap();
        fs::create_dir(root.join("inside")).unwrap();
        fs::write(root.join("inside/file.txt"), b"ok").unwrap();
        symlink(outside, root.join("linked-dir")).unwrap();
        symlink(
            outside.join("secret.txt"),
            root.join("inside/linked-file.txt"),
        )
        .unwrap();
        let root_handle = open_ambient_dir(root, cap_primitives::ambient_authority()).unwrap();

        assert!(
            open_relative_file(&root_handle, &["inside".to_owned(), "file.txt".to_owned()]).is_ok()
        );
        assert!(open_relative_file(
            &root_handle,
            &["linked-dir".to_owned(), "secret.txt".to_owned()]
        )
        .is_err());
        assert!(open_relative_file(
            &root_handle,
            &["inside".to_owned(), "linked-file.txt".to_owned()]
        )
        .is_err());
    }

    #[test]
    fn serves_files_ranges_and_revalidation() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let root = tempfile::tempdir().unwrap();
        let original = b"0123456789".repeat(10_000);
        fs::create_dir(root.path().join("css")).unwrap();
        fs::write(root.path().join("css/site.css"), &original).unwrap();
        let service = service(root.path());
        runtime.block_on(async {
            let whole = service
                .serve(plan("/css/site.css"), &Method::GET, &HeaderMap::new())
                .await;
            assert_eq!(whole.status(), StatusCode::OK);
            assert_eq!(whole.headers()[CACHE_CONTROL], "no-cache");
            assert_eq!(whole.headers()[CONTENT_TYPE], "text/css; charset=utf-8");
            let etag = whole.headers()[ETAG].clone();
            let bytes = whole.into_body().collect().await.unwrap().to_bytes();
            assert_eq!(bytes.as_ref(), &original[..]);

            let mut conditional = HeaderMap::new();
            conditional.insert(IF_NONE_MATCH, etag);
            let unchanged = service
                .serve(plan("css/site.css"), &Method::GET, &conditional)
                .await;
            assert_eq!(unchanged.status(), StatusCode::NOT_MODIFIED);

            let mut ranged = HeaderMap::new();
            ranged.insert(RANGE, "bytes=3-7".parse().unwrap());
            let part = service
                .serve(plan("css/site.css"), &Method::GET, &ranged)
                .await;
            assert_eq!(part.status(), StatusCode::PARTIAL_CONTENT);
            let bytes = part.into_body().collect().await.unwrap().to_bytes();
            assert_eq!(bytes.as_ref(), b"34567");

            let missing = service
                .serve(plan("css/other.css"), &Method::GET, &HeaderMap::new())
                .await;
            assert_eq!(missing.status(), StatusCode::NOT_FOUND);

            let post = service
                .serve(plan("css/site.css"), &Method::POST, &HeaderMap::new())
                .await;
            assert_eq!(post.status(), StatusCode::METHOD_NOT_ALLOWED);
        });
    }

    #[test]
    fn single_range_parser_is_bounded_and_deterministic() {
        fn headers(value: &'static str) -> HeaderMap {
            let mut headers = HeaderMap::new();
            headers.insert(RANGE, hyper::header::HeaderValue::from_static(value));
            headers
        }

        assert_eq!(
            parse_range(&headers("bytes=2-4"), 10),
            RangeSelection::Range { start: 2, end: 4 }
        );
        assert_eq!(
            parse_range(&headers("bytes=7-"), 10),
            RangeSelection::Range { start: 7, end: 9 }
        );
        assert_eq!(
            parse_range(&headers("bytes=-3"), 10),
            RangeSelection::Range { start: 7, end: 9 }
        );
        assert_eq!(
            parse_range(&headers("bytes=99-"), 10),
            RangeSelection::Unsatisfiable
        );
        assert_eq!(
            parse_range(&headers("bytes=0-1,4-5"), 10),
            RangeSelection::Ignore
        );
        assert_eq!(
            parse_range(&headers("items=0-1"), 10),
            RangeSelection::Ignore
        );
    }

    #[test]
    fn preconditions_follow_if_match_and_if_none_match_precedence() {
        let modified = UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        let etag = weak_etag(10, Some(modified));
        let mut headers = HeaderMap::new();
        headers.insert(
            IF_MATCH,
            hyper::header::HeaderValue::from_static("\"strong\""),
        );
        headers.insert(IF_NONE_MATCH, etag.parse().unwrap());
        assert_eq!(
            precondition_status(&headers, &etag, Some(modified), &Method::GET),
            Some(StatusCode::PRECONDITION_FAILED)
        );

        headers.remove(IF_MATCH);
        assert_eq!(
            precondition_status(&headers, &etag, Some(modified), &Method::GET),
            Some(StatusCode::NOT_MODIFIED)
        );
    }
}
