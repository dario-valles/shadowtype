# Third-Party Notices

Shadowtype is licensed under the MIT License (see [LICENSE](LICENSE)).

Release builds (`./scripts/make-app.sh`) bundle the following third-party
libraries into `Shadowtype.app/Contents/Frameworks/`. Their licenses and
copyright notices are reproduced below, as required.

---

## llama.cpp / ggml — MIT License

`libllama`, `libggml`, `libggml-base` come from the llama.cpp / ggml project
(https://github.com/ggml-org/llama.cpp), installed via the Homebrew `llama.cpp`
formula.

```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## LLVM OpenMP runtime (`libomp`) — Apache License 2.0 with LLVM Exceptions

`libomp` (an llama.cpp/ggml runtime dependency, from the Homebrew `libomp`
formula) is part of the LLVM Project and is licensed under the Apache License
2.0 with LLVM Exceptions. Full text: https://llvm.org/LICENSE.txt

---

## Language models (downloaded at runtime — NOT bundled)

Shadowtype does not ship any model weights. Models in GGUF format are downloaded
on demand from Hugging Face at the user's request. Each model is governed by its
own license, for example:

- **Google Gemma** models — [Gemma Terms of Use](https://ai.google.dev/gemma/terms)
- **Qwen** (Alibaba) models — Apache License 2.0
- **Meta Llama** models — [Llama Community License](https://www.llama.com/llama-downloads/)

Review and accept the applicable model license before downloading or using a
model. Bring-your-own-model (custom GGUF) follows whatever license you obtain
the weights under.
