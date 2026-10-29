//! Content hashes for `Crypt.hash!` and `Crypt.hash_file!`, with ring, the
//! crypto backend the TLS stack already links.
use core::mem::ManuallyDrop;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use ring::digest::{Algorithm, Context, SHA1_FOR_LEGACY_USE_ONLY, SHA256};

use crate::roc_platform_abi::*;

const READ_CHUNK: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Hash {
    Sha1,
    Sha256,
}

impl Hash {
    fn algorithm(self) -> &'static Algorithm {
        match self {
            Hash::Sha1 => &SHA1_FOR_LEGACY_USE_ONLY,
            Hash::Sha256 => &SHA256,
        }
    }
}

pub(crate) fn hash_bytes(bytes: &[u8], hash: Hash) -> String {
    let mut context = Context::new(hash.algorithm());
    context.update(bytes);
    hex(context.finish().as_ref())
}

/// Reads a piece at a time, so memory stays flat however large the file is,
/// and gives up between pieces once a caught signal is pending.
pub(crate) fn hash_file(path: &Path, hash: Hash) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut context = Context::new(hash.algorithm());
    let mut buffer = vec![0u8; READ_CHUNK];
    loop {
        if crate::signals::is_pending() {
            return Err(io::ErrorKind::Interrupted.into());
        }
        match file.read(&mut buffer) {
            Ok(0) => return Ok(hex(context.finish().as_ref())),
            Ok(count) => context.update(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    out
}

// Roc ABI

fn hash_from_roc(algorithm: Sha1OrSha256) -> Hash {
    match algorithm {
        Sha1OrSha256::Sha1 => Hash::Sha1,
        Sha1OrSha256::Sha256 => Hash::Sha256,
    }
}

#[no_mangle]
pub extern "C" fn hosted_crypt_hash(
    bytes: RocListWith<u8, false>,
    algorithm: Sha1OrSha256,
) -> RocStr {
    let roc_host = crate::roc_host();
    let digest = hash_bytes(bytes.as_slice(), hash_from_roc(algorithm));
    unsafe { bytes.decref(roc_host) };
    RocStr::from_str(&digest, roc_host)
}

#[no_mangle]
pub extern "C" fn hosted_crypt_hash_file(
    path: UnixBytesOrUtf8OrWindowsU16s,
    algorithm: Sha1OrSha256,
) -> HostCryptHashFileResult {
    let roc_host = crate::roc_host();
    let digest = crate::path_from_native(path, roc_host)
        .and_then(|path| hash_file(&path, hash_from_roc(algorithm)));
    let error = match digest {
        Ok(digest) => {
            return HostCryptHashFileResult {
                payload: HostCryptHashFileResultPayload {
                    ok: ManuallyDrop::new(RocStr::from_str(&digest, roc_host)),
                },
                tag: HostCryptHashFileResultTag::Ok,
            }
        }
        Err(error) if error.kind() == io::ErrorKind::Interrupted => FileErrOrInterrupted {
            payload: FileErrOrInterruptedPayload { interrupted: [] },
            tag: FileErrOrInterruptedTag::Interrupted,
        },
        Err(error) => FileErrOrInterrupted {
            payload: FileErrOrInterruptedPayload {
                file_err: ManuallyDrop::new(crate::io_err_from_io(&error, roc_host)),
            },
            tag: FileErrOrInterruptedTag::FileErr,
        },
    };
    HostCryptHashFileResult {
        payload: HostCryptHashFileResultPayload {
            err: ManuallyDrop::new(error),
        },
        tag: HostCryptHashFileResultTag::Err,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_match_known_digests() {
        assert_eq!(
            hash_bytes(b"hello", Hash::Sha256),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
        assert_eq!(
            hash_bytes(b"hello", Hash::Sha1),
            "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"
        );
        assert_eq!(
            hash_bytes(b"", Hash::Sha256),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn a_file_hashes_like_its_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("big.bin");
        let bytes: Vec<u8> = (0..(3 * READ_CHUNK + 17))
            .map(|i| (i % 251) as u8)
            .collect();
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(
            hash_file(&path, Hash::Sha256).unwrap(),
            hash_bytes(&bytes, Hash::Sha256)
        );
    }
}
