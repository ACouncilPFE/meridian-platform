"""Field-level envelope encryption for PHI.

Why field-level on top of Aurora's storage encryption?
  * Storage encryption protects disks and snapshots. It does nothing against
    a leaked DB credential, an over-broad read replica grant, or a SQL dump.
  * With field-level encryption a dump of `patients` is ciphertext unless the
    caller can ALSO call kms:Decrypt on the PHI key, which is a separate,
    audited (CloudTrail) permission held only by the API's task role.

Design:
  * KMS generates a 256-bit data key (DEK); we encrypt fields locally with
    AES-256-GCM and store the KMS-wrapped DEK alongside the ciphertext.
  * Associated data binds each ciphertext to (table, column, row id) so a
    ciphertext copied into another row or column fails to decrypt.
  * DEKs are cached and rotated after `max_uses` encryptions to bound both
    KMS cost/latency and the blast radius of any single key.
  * Blind indexes (HMAC-SHA256 with a separate key) allow exact-match lookup
    (e.g. by email) without decrypting the whole table.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import threading
from dataclasses import dataclass
from typing import Protocol

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

TOKEN_VERSION = "v1"  # noqa: S105 (format version tag, not a secret)


class KeyProvider(Protocol):
    def generate_data_key(self) -> tuple[bytes, bytes]:
        """Return (plaintext_key, wrapped_key)."""

    def unwrap_data_key(self, wrapped: bytes) -> bytes:
        """Return plaintext key for a wrapped key."""


class KmsKeyProvider:
    """Production provider backed by AWS KMS."""

    def __init__(self, key_id: str, client=None, encryption_context: dict[str, str] | None = None):
        import boto3  # imported lazily so tests/local dev don't need AWS

        self._key_id = key_id
        self._kms = client or boto3.client("kms")
        self._ctx = encryption_context or {"purpose": "phi-field-encryption"}

    def generate_data_key(self) -> tuple[bytes, bytes]:
        resp = self._kms.generate_data_key(KeyId=self._key_id, KeySpec="AES_256", EncryptionContext=self._ctx)
        return resp["Plaintext"], resp["CiphertextBlob"]

    def unwrap_data_key(self, wrapped: bytes) -> bytes:
        resp = self._kms.decrypt(CiphertextBlob=wrapped, EncryptionContext=self._ctx, KeyId=self._key_id)
        return resp["Plaintext"]


class LocalKeyProvider:
    """Dev/test provider: wraps DEKs with a local master key. Never used in prod
    (settings validation refuses it when DEPLOY_ENV=prod)."""

    def __init__(self, master_key: bytes):
        if len(master_key) != 32:
            raise ValueError("master key must be 32 bytes")
        self._aead = AESGCM(master_key)

    def generate_data_key(self) -> tuple[bytes, bytes]:
        dek = AESGCM.generate_key(bit_length=256)
        nonce = os.urandom(12)
        return dek, nonce + self._aead.encrypt(nonce, dek, b"dek")

    def unwrap_data_key(self, wrapped: bytes) -> bytes:
        return self._aead.decrypt(wrapped[:12], wrapped[12:], b"dek")


class DecryptionError(Exception):
    pass


@dataclass
class _CachedKey:
    plaintext: bytes
    wrapped: bytes
    uses: int = 0


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class FieldEncryptor:
    def __init__(self, provider: KeyProvider, blind_index_key: bytes, max_uses: int = 1000):
        self._provider = provider
        self._bidx_key = blind_index_key
        self._max_uses = max_uses
        self._current: _CachedKey | None = None
        self._unwrap_cache: dict[bytes, bytes] = {}
        self._lock = threading.Lock()

    # -- public API ---------------------------------------------------------
    def encrypt(self, plaintext: str, *, aad: str) -> str:
        key = self._key_for_encrypt()
        nonce = os.urandom(12)
        ct = AESGCM(key.plaintext).encrypt(nonce, plaintext.encode(), aad.encode())
        return ".".join([TOKEN_VERSION, _b64(key.wrapped), _b64(nonce), _b64(ct)])

    def decrypt(self, token: str, *, aad: str) -> str:
        try:
            version, wrapped_b64, nonce_b64, ct_b64 = token.split(".")
        except ValueError as e:
            raise DecryptionError("malformed token") from e
        if version != TOKEN_VERSION:
            raise DecryptionError(f"unsupported token version {version!r}")
        wrapped = _unb64(wrapped_b64)
        key = self._unwrap(wrapped)
        try:
            pt = AESGCM(key).decrypt(_unb64(nonce_b64), _unb64(ct_b64), aad.encode())
        except Exception as e:  # InvalidTag
            raise DecryptionError("authentication failed (wrong row/column or tampered)") from e
        return pt.decode()

    def blind_index(self, value: str) -> str:
        normalized = value.strip().lower().encode()
        return hmac.new(self._bidx_key, normalized, hashlib.sha256).hexdigest()

    # -- internals ----------------------------------------------------------
    def _key_for_encrypt(self) -> _CachedKey:
        with self._lock:
            if self._current is None or self._current.uses >= self._max_uses:
                pt, wrapped = self._provider.generate_data_key()
                self._current = _CachedKey(pt, wrapped)
                self._unwrap_cache[wrapped] = pt
            self._current.uses += 1
            return self._current

    def _unwrap(self, wrapped: bytes) -> bytes:
        with self._lock:
            cached = self._unwrap_cache.get(wrapped)
        if cached is not None:
            return cached
        pt = self._provider.unwrap_data_key(wrapped)
        with self._lock:
            if len(self._unwrap_cache) > 10_000:
                self._unwrap_cache.clear()
            self._unwrap_cache[wrapped] = pt
        return pt


def aad_for(table: str, column: str, row_id: str) -> str:
    return f"{table}:{column}:{row_id}"
