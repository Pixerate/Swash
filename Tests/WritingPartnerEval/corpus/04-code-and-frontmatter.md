---
title: dont change i or teh inside front matter
author: j. smith
draft: true
summary: its important that metadata keys like id and ok stay untouched
---

# Working With Code and Metadata

Technical documents mix ordinary prose with source code, shell commands, and YAML front matter. When I'm writing a guide, I want the partner to tidy my sentences, but it mustn't touch a single character inside backticks or code fences.

For example, an inline span like `dont touch i or teh` or `let id = its_value` is literal code, not English prose. Even if I mention `ok` or `im` or `doesnt` inside backticks, the characters must stay exactly as written.

```swift
// dont change i or teh in comments or strings inside a fenced block
struct Entry {
    let id: String
    var ok: Bool = false

    func describe() -> String {
        let message = "i dont think teh parser should touch this"
        return "\(id): \(message)"
    }
}
```

I've tested shell snippets with tilde fences as well, because people use them when a script itself contains backticks. It's a small detail, but it saves hours of frustration when copying commands into a terminal.

~~~bash
#!/usr/bin/env bash
# if i dont pass teh flag, its going to exit early
for id in alpha beta; do
    echo "checking $id: ok"
done
~~~

How should the editor handle an unclosed backtick while you're still typing a span? It counts the backticks earlier on the line, so it knows you're inside code before the closing delimiter lands. That's why I can type identifiers without fighting the spell checker, and everything stays OK when the span closes.
