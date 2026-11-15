# Mathematical Notation and Data Tables

Scientific notes and engineering benchmarks rely on inline equations, display formulas, and structured tables. When I'm writing up an experiment, I don't want a text helper turning variable names like $i$ or $x_i$ into uppercase pronouns.

In an inline expression such as $f(i) = x_i + \text{dont} - \text{teh}$, the letters between dollar signs belong to TeX, not prose. The same rule holds for display blocks, where multi-line equations define the model.

$$
\mathcal{L}(i, \theta) = \sum_{i=1}^{n} \left( y_i - \hat{y}_i \right)^2 + \lambda \|\theta\|_2^2
$$

```math
\text{score}(i) = \frac{\text{restored}_i}{\text{restored}_i + \text{dont}_i + \text{teh}_i}
```

I've put the benchmark numbers into a table below so we can compare the passes side by side. Inside a table cell, short notes like `dont` or `i` or `ok` must never be rewritten by the background voice.

| Pass | Complexity | Notes | Status |
| :--- | :---: | :--- | ---: |
| Block scan | O(n) | dont reparse unchanged blocks for i | ok |
| Inline parse | O(k) | teh delimiter stack stays linear | dont touch |
| Math snapshot | cached | its keyed by formula hash and id | i |

What do these numbers tell us about editor responsiveness on long files? When the styling pass only touches the edited paragraph, typing stays smooth even in a two-thousand-line document. I'd still keep an eye on syntax highlighting in huge code blocks, but the current token limit works well and keeps frame times OK.
