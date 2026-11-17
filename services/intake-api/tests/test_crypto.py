import pytest

from intake_api.crypto import DecryptionError, FieldEncryptor, LocalKeyProvider, aad_for


class CountingProvider(LocalKeyProvider):
    def __init__(self):
        super().__init__(b"k" * 32)
        self.generated = 0
        self.unwrapped = 0

    def generate_data_key(self):
        self.generated += 1
        return super().generate_data_key()

    def unwrap_data_key(self, wrapped):
        self.unwrapped += 1
        return super().unwrap_data_key(wrapped)


@pytest.fixture
def enc():
    return FieldEncryptor(LocalKeyProvider(b"m" * 32), b"b" * 32)


def test_roundtrip(enc):
    token = enc.encrypt("Jane Doe", aad=aad_for("patients", "name", "1"))
    assert "Jane" not in token
    assert enc.decrypt(token, aad=aad_for("patients", "name", "1")) == "Jane Doe"


def test_ciphertext_bound_to_row(enc):
    token = enc.encrypt("Jane Doe", aad=aad_for("patients", "name", "1"))
    with pytest.raises(DecryptionError):
        enc.decrypt(token, aad=aad_for("patients", "name", "2"))


def test_ciphertext_bound_to_column(enc):
    token = enc.encrypt("1990-01-01", aad=aad_for("patients", "dob", "1"))
    with pytest.raises(DecryptionError):
        enc.decrypt(token, aad=aad_for("patients", "name", "1"))


def test_tamper_detected(enc):
    token = enc.encrypt("x", aad="a")
    head, ct = token.rsplit(".", 1)
    tampered = head + "." + ("A" if ct[0] != "A" else "B") + ct[1:]
    with pytest.raises(DecryptionError):
        enc.decrypt(tampered, aad="a")


def test_nondeterministic(enc):
    assert enc.encrypt("same", aad="a") != enc.encrypt("same", aad="a")


def test_blind_index_normalizes_and_is_deterministic(enc):
    assert enc.blind_index("Jane@Example.com ") == enc.blind_index("jane@example.com")
    assert enc.blind_index("a@example.com") != enc.blind_index("b@example.com")


def test_data_key_rotation_and_cache():
    provider = CountingProvider()
    enc = FieldEncryptor(provider, b"b" * 32, max_uses=3)
    tokens = [enc.encrypt(str(i), aad="a") for i in range(7)]
    assert provider.generated == 3  # 3 + 3 + 1
    # Cached unwrap: our own keys never round-trip to the provider.
    assert [enc.decrypt(t, aad="a") for t in tokens] == [str(i) for i in range(7)]
    assert provider.unwrapped == 0

    fresh = FieldEncryptor(provider, b"b" * 32)
    fresh.decrypt(tokens[0], aad="a")
    fresh.decrypt(tokens[1], aad="a")  # same DEK as tokens[0]
    assert provider.unwrapped == 1


def test_malformed_token(enc):
    with pytest.raises(DecryptionError):
        enc.decrypt("not-a-token", aad="a")
