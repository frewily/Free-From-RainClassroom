"""PyNaCl sealed box helper. Inputs stay in stdin, not command arguments or files."""
import base64
import json
import sys


def main():
    from nacl.public import PrivateKey, PublicKey, SealedBox

    if sys.argv[1:] == ["--self-test"]:
        private = PrivateKey.generate()
        plaintext = b"synthetic-rain-manager-self-test"
        ciphertext = SealedBox(private.public_key).encrypt(plaintext)
        if SealedBox(private).decrypt(ciphertext) != plaintext:
            raise ValueError("sealed_box_roundtrip_failed")
        print(json.dumps({"sealed_box_roundtrip": True}))
        return
    if sys.argv[1:]:
        raise ValueError("unexpected_arguments")
    data = sys.stdin.buffer.read(4097)
    if len(data) > 4096:
        raise ValueError("oversized_input")
    value = json.loads(data)
    if set(value) != {"public_key", "plaintext"}:
        raise ValueError("invalid_input")
    key = base64.b64decode(value["public_key"], validate=True)
    text = value["plaintext"]
    if len(key) != 32 or not isinstance(text, str) or not 1 <= len(text.encode()) <= 512:
        raise ValueError("invalid_input")
    encrypted = SealedBox(PublicKey(key)).encrypt(text.encode())
    print(base64.b64encode(encrypted).decode())


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never include input or third-party exception details in diagnostics.
        print("sealed_box_helper_failed", file=sys.stderr)
        sys.exit(1)
