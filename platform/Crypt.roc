import Host
import IOErr
import Path

## Content hashes, as lowercase hex.
##
## [hash_file!] reads the file in the host, a piece at a time, so a large
## file never passes through Roc.
Crypt :: [].{

	## Hash algorithms supported by [hash!] and [hash_file!].
	Algorithm : [Sha1, Sha256]

	## Hash bytes, returning a lowercase hex digest.
	##
	## ```roc
	## digest = Crypt.hash!(Str.to_utf8("hello"), Sha256)
	## ```
	hash! : List(U8), Algorithm => Str
	hash! = |bytes, algorithm| Host.crypt_hash!(bytes, algorithm)

	## Hash a file's content, returning a lowercase hex digest.
	hash_file! : Path, Algorithm => Try(Str, [PathErr(IOErr, Path), Interrupted])
	hash_file! = |path, algorithm|
		match Host.crypt_hash_file!(Path.to_raw(path), algorithm) {
			Ok(digest) => Ok(digest)
			Err(FileErr(err)) => Err(PathErr(err, path))
			Err(Interrupted) => Err(Interrupted)
		}
}
