# Batch

**Prefer `offsider batch`** for multi-step flows. Batch runs input steps (`rn devmenu <item>` among them), `sleep`, and the read steps `wait`, `assert`, `screenshot` and `describe-ui`, written like the standalone commands without `--device`, in a single process:

- One tool call and one agent turn instead of many, which cuts latency and cost.
- One HID session serves every step. On Android one UiAutomation helper serves every step, so several reads pay its start once.
- Steps run in order, each before the next is resolved, so earlier taps can trigger navigation and later selector taps find newly appeared elements (with `--wait-timeout`).
- `batch` takes the device lock once for all its steps.

**Fall back to separate commands** when:

- A step's parameters depend on inspecting an earlier result (for example parsing `describe-ui` JSON to choose coordinates).
- You use `slider`: batch steps do not support slider verification.
- You need `--verify`: batch steps reject `--verify`, `--verify-timeout`, `--retries` and `--json`. Run that input on its own with `--verify`, or follow it with a `wait` or `assert` step.

```bash
offsider batch --device <DEVICE_ID> --json \
  --step 'tap --id open-filters' --step 'wait --id apply-filters' \
  --step 'tap --id apply-filters' --step 'assert --id filter-state --has-value Applied' \
  --step 'screenshot --output after.png --scale points' --step 'describe-ui --summary'
```

## Output

`batch --json` prints one JSON line per step to stdout (`step`, `kind`, `line`, `ok`, `ms`; `exitCode` and the `error` object on failure; `met`, `reason`, `match` for `wait` and `assert`; the screenshot fields; `tree` or `output` for `describe-ui`), then a summary line with `steps`, `failed` and `dispatched` (`yes`, `no` or `unknown`: whether any step sent input). After a failure, resend the whole batch only when `dispatched` is `no`; otherwise check the screen and resend from the failed step. Parse it instead of the text output. A `type` step's record shows `type <N characters>`, never the text, and `--mask-text`, `--mask-label` and `--grep` values show as `<N characters>` too. The batch exits with the code of its first step that failed to run, else 5 when a `wait`, `assert` or `screenshot --compare` condition was not met, else 0. Keep output quiet by default; add `--verbose` only when troubleshooting. `--mask-secure` masks password fields in every screenshot step; a step can add its own masks, such as `screenshot --mask-emails`, and an evidence run's masks always apply too (`guide evidence`).

## Animations and transitions

- `--wait-timeout <seconds>` (on the batch, or on one tap step to override it) makes selector taps poll the tree until the element is on screen, not merely mounted, or the timeout expires. `--poll-interval <seconds>` sets the polling frequency (default 0.25 s).
- Selector tap steps that follow an input step check whether the target moved since the tree read before that input, and if so wait out the rest of 500 ms and tap it where it is now (`--no-settle` on the batch or the step turns this off). An animation longer than 500 ms still needs `wait --settled` first.
- Batch reuses an accessibility snapshot only until a step sends input or sleeps, so a selector step after a tap reads the new screen. A read straight after input can still see the old screen while the app reacts: add `--wait-timeout`. `--ax-cache perStep` reads fresh for every selector step.
- Before coordinate taps, use a `wait` step (`wait --settled`, or `wait --region <x,y,w,h> --stable` for motion the tree cannot see); use `sleep <seconds>` only as a last resort.
- Selector taps in batch share direct `tap` semantics, including switch and toggle handling and `--tap-style automatic`. Batch-level `--tap-style physical|simulator` sets the default for tap steps; a step's own `tap --tap-style` overrides it.
- If `tap --label` reports multiple matches and none of them has an `id`, narrow with `--element-type` or fall back to `tap -x <X> -y <Y>` for that step.

## Rules

- Use exactly one step source per run: `--step`, `--file` or `--stdin`.
- Steps run in order and stop at the first failure; add `--continue-on-error` for best-effort runs.
- Do not pass `--device` inside step lines; keep it on the batch.
- After an exploratory run, keep the working sequence as a `batch --file` and re-run it once to prove it replays.
