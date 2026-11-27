"""Read-only CET log rotation cursor (MIT, original DeepBide code).

Derived from our verified internal rotation follower. This module only
handles file identity and byte continuity; the public expanded reader
owns the existing observation validation and generation contract.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path

LIMIT = 64 * 1024 * 1024


class CETFollowError(ValueError):
    """A source boundary could not be verified."""


def _native_log_stat(path: Path):
    """Do not follow links/reparse points or accept ambiguous file identities."""
    st = path.lstat()
    import stat
    if (not stat.S_ISREG(st.st_mode) or not st.st_ino
            or getattr(st, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise CETFollowError("FOLLOW_NATIVE_LOG_IDENTITY_UNVERIFIED")
    return st


def _log_identity(st):
    return (st.st_dev, st.st_ino)


def _native_prefix(stream, length):
    """Hash exactly the witnessed prefix in bounded reads; retain no raw log."""
    if not 0 <= length <= LIMIT:
        raise CETFollowError("FOLLOW_NATIVE_SOURCE_BOUND_EXCEEDED")
    digest = hashlib.sha256()
    tail = b""
    remaining = length
    while remaining:
        block = stream.read(min(remaining, 256 * 1024))
        if not block:
            raise CETFollowError("FOLLOW_NATIVE_PREFIX_TRUNCATED")
        digest.update(block)
        tail = (tail + block)[-128:]
        remaining -= len(block)
    return digest, tail


class CETLogCursor:
    """Read-only cursor for the existing CET rotating logger.

    Only the immediate, same-file-identity scripting.1.log can bridge a
    replacement. Exact prefix hashes include the ignored initial EOF bytes.
    No directory search, log replay as live facts, or guessing by sequence.
    """

    def __init__(self, source):
        self.source = source
        self.identity = None
        self.offset = 0
        self.digest = hashlib.sha256()
        self.tail = b""
        self.mtime_ns = None

    def rebase(self):
        st = _native_log_stat(self.source)
        with self.source.open("rb") as stream:
            witness = os.fstat(stream.fileno())
            if _log_identity(witness) != _log_identity(st):
                raise CETFollowError("FOLLOW_NATIVE_REBASE_BOUNDARY_CHANGED")
            digest, tail = _native_prefix(stream, witness.st_size)
            after = os.fstat(stream.fileno())
            if (_log_identity(_native_log_stat(self.source)) != _log_identity(witness)
                    or after.st_size < witness.st_size):
                raise CETFollowError("FOLLOW_NATIVE_REBASE_BOUNDARY_CHANGED")
        self.identity = _log_identity(witness)
        self.offset = witness.st_size
        self.digest, self.tail = digest, tail
        self.mtime_ns = witness.st_mtime_ns

    def read(self):
        """Return append, changed, missing or retry; commit only witnessed bytes."""
        try:
            st = _native_log_stat(self.source)
            if self.identity is None or _log_identity(st) != self.identity or st.st_size < self.offset:
                return "changed", b"", False
            if st.st_size > LIMIT:
                raise CETFollowError("FOLLOW_NATIVE_SOURCE_BOUND_EXCEEDED")
            with self.source.open("rb") as stream:
                witness = os.fstat(stream.fileno())
                if _log_identity(witness) != self.identity or witness.st_size < self.offset:
                    return "changed", b"", False
                if witness.st_size > LIMIT:
                    raise CETFollowError("FOLLOW_NATIVE_SOURCE_BOUND_EXCEEDED")
                if self.tail:
                    stream.seek(self.offset - len(self.tail))
                    if stream.read(len(self.tail)) != self.tail:
                        return "changed", b"", False
                if witness.st_size == self.offset and witness.st_mtime_ns == self.mtime_ns:
                    return "append", b"", False
                # On growth or an observed rewrite, verify the entire prior prefix.
                # This also detects truncate/refill with a copied 128-byte tail.
                stream.seek(0)
                digest, tail = _native_prefix(stream, self.offset)
                if digest.digest() != self.digest.digest() or tail != self.tail:
                    return "changed", b"", False
                chunk = stream.read(min(witness.st_size - self.offset, 256 * 1024))
                end = self.offset + len(chunk)
                if len(chunk) != min(witness.st_size - self.offset, 256 * 1024):
                    return "changed", b"", False
                after = os.fstat(stream.fileno())
                if (_log_identity(_native_log_stat(self.source)) != self.identity
                        or after.st_size < end):
                    return "changed", b"", False
                if after.st_size == witness.st_size and after.st_mtime_ns != witness.st_mtime_ns:
                    # A flush may update mtime without changing bytes. Retry
                    # from the uncommitted cursor; do not invent a rotation.
                    return "retry", b"", False
                # A retained boundary is checked on the same open handle.
                if self.tail:
                    stream.seek(self.offset - len(self.tail))
                    if stream.read(len(self.tail)) != self.tail:
                        return "changed", b"", False
                digest.update(chunk)
                self.offset, self.digest = end, digest
                self.tail = (self.tail + chunk)[-128:]
                self.mtime_ns = after.st_mtime_ns
                return "append", chunk, after.st_size > end
        except FileNotFoundError:
            return "missing", b"", False

    def rotate(self):
        """Recover the unread tail of the *same* archived file, or fail closed."""
        current = _native_log_stat(self.source)
        new_identity = _log_identity(current)
        if self.identity is None or new_identity == self.identity:
            raise CETFollowError("FOLLOW_NATIVE_ROTATION_NOT_RENAME")
        archive = self.source.with_name("scripting.1.log")
        try:
            old = _native_log_stat(archive)
        except FileNotFoundError:
            raise CETFollowError("FOLLOW_NATIVE_ROTATION_ARCHIVE_MISSING") from None
        if _log_identity(old) != self.identity:
            raise CETFollowError("FOLLOW_NATIVE_ROTATION_ARCHIVE_IDENTITY")
        with archive.open("rb") as stream:
            witness = os.fstat(stream.fileno())
            if (_log_identity(witness) != self.identity
                    or not self.offset <= witness.st_size <= LIMIT):
                raise CETFollowError("FOLLOW_NATIVE_ROTATION_ARCHIVE_BOUNDARY")
            digest, tail = _native_prefix(stream, self.offset)
            if digest.digest() != self.digest.digest() or tail != self.tail:
                raise CETFollowError("FOLLOW_NATIVE_ROTATION_PREFIX_MISMATCH")
            suffix = stream.read(witness.st_size - self.offset)
            after = os.fstat(stream.fileno())
            retained = _native_log_stat(archive)
            if (len(suffix) != witness.st_size - self.offset
                    or after.st_size != witness.st_size or retained.st_size != witness.st_size
                    or after.st_mtime_ns != witness.st_mtime_ns
                    or retained.st_mtime_ns != witness.st_mtime_ns
                    or _log_identity(retained) != self.identity
                    or _log_identity(_native_log_stat(self.source)) != new_identity):
                raise CETFollowError("FOLLOW_NATIVE_ROTATION_ARCHIVE_CHANGED")
        # Never form a JSON row from bytes belonging to two different files.
        if not (suffix or self.tail).endswith(b"\n"):
            raise CETFollowError("FOLLOW_NATIVE_ROTATION_PARTIAL_ARCHIVE_LINE")
        self.identity = new_identity
        self.offset, self.digest, self.tail = 0, hashlib.sha256(), b""
        self.mtime_ns = None
        return suffix
