<@U12345> I'm looking at the latency spike on the preview worker and I don't think it's coming from the parser

> worker-03 reported 420ms on <https://status.example.com/dont/i|the health check endpoint>
> queue depth stayed flat, so the bottleneck isn't in the job dispatcher

I've pulled the trace from https://logs.example.com/teh/worker-03 and there's a slow font load when WebKit starts cold. once the font cache is warm, it's back under 15ms and everything looks ok

```
2026-11-15T09:14:02Z worker=03 status=ok dont_retry=true id=req_99
2026-11-15T09:14:03Z worker=03 teh_cache=miss duration_ms=418 i=1
```

I'd keep the warm-up probe enabled in staging so we don't hit this on the first snapshot after deploy. I'll watch the graphs for another hour, and if it's stable we've got a clean fix without touching the renderer
