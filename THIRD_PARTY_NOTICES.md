# Third-party notices

Isola's original source code is distributed under the [MIT License](LICENSE).
The networking helper links the following separately licensed Go modules:

| Module | License |
| --- | --- |
| [gVisor](https://github.com/google/gvisor) | Apache-2.0 |
| [gopacket](https://github.com/google/gopacket) | BSD-3-Clause |
| [google/btree](https://github.com/google/btree) | Apache-2.0 |
| [golang.org/x/net](https://cs.opensource.google/go/x/net) | BSD-3-Clause |
| [golang.org/x/sys](https://cs.opensource.google/go/x/sys) | BSD-3-Clause |
| [golang.org/x/time](https://cs.opensource.google/go/x/time) | BSD-3-Clause |

Exact versions are pinned in `Network/go.mod` and `Network/go.sum`. The build
copies dependency LICENSE, NOTICE and COPYING files into
`Isola.app/Contents/Resources/Licenses`. Go's runtime license is bundled there too.

The Isola application icon was created with OpenAI image generation; its prompts
are recorded in `Assets/IsolaIcon.prompt.txt`. Interface symbols use Apple's
system SF Symbols through AppKit/SwiftUI. macOS restore images are downloaded
directly from Apple and are not included in the source or release archive.
