package com.nts.example

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Initialise `rustls-platform-verifier` against the Android system
    // trust store before Flutter loads the Dart engine. The verifier is
    // consulted by the `nts` Rust crate during the NTS-KE TLS 1.3
    // handshake (RFC 8915 §4) and panics on first use unless this
    // bootstrap has run. See `RustlsBootstrap` for the contract.
    override fun onCreate(savedInstanceState: Bundle?) {
        RustlsBootstrap.init(this)
        super.onCreate(savedInstanceState)
    }
}
