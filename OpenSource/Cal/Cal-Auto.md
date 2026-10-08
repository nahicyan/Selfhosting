# Cal.diy Auto-Cancel

Cancels a booking automatically, with a stated reason, when the answer to a **number question** is above a limit. Cal.diy has no such setting (no Workflows in this fork, and a Number question has no maximum), so a small receiver runs next to it.

Current setup (the Interview event type):

| | |
|---|---|
| Question | `What is your expected hourly rate ($ USD)?` |
| Cancel when | answer **> 14** (14 is kept, 14.01 is cancelled) |
| Reason emailed | `Sorry, you are unaffordable for us. But we wish you best of luck. Thank you.` |

# ==⛔ Needs SMTP configured in Cal's `.env` — the reason is delivered by email ⛔==
# ==⛔ Seated event types and event types with "disable cancelling" cannot be auto-cancelled ⛔==

## How it works

```
booking made
  -> Cal.diy sends a signed webhook (Booking created / Booking requested)
  -> auto-cancel container checks the signature and the answer
  -> answer above the limit: it calls Cal.diy's own /api/cancel with the reason
  -> Cal.diy cancels the booking and emails the reason to the attendee
```

The receiver runs as one more service in the existing Cal.diy Compose project. Cal.diy reaches it at `http://auto-cancel:8787` and it reaches Cal.diy at `http://calcom:3000`, both on the project's private network. **Nothing is published on the host**, so it needs no Nginx block and no certificate.

## Files

All in `OpenSource/Cal/scripts/`:

| File | What it is |
|---|---|
| `cal-auto-cancel.py` | The receiver. Runs all the time in the container and does the cancelling. |
| `cal-auto-cancel-install.sh` | One-time setup: asks the questions, writes the config, starts the container. |
| `cal-auto-cancel-uninstall.sh` | Stops the container and removes everything the installer added. |

What the installer adds to the Cal install directory (`/var/www/docker/cal/<domain>` by default). It does not touch `docker-compose.yml` or `.env`:

```
docker-compose.override.yml   the auto-cancel service (Compose merges it automatically,
                              so the usual `docker compose up -d` includes it)
auto-cancel.env               WEBHOOK_SECRET, FIELD, MAX_VALUE   (mode 600)
auto-cancel/
  cal-auto-cancel.py          the receiver (mounted read-only into the container)
  reason.txt                  the cancellation reason
```

The container runs `python:3.13-slim` as a non-root user with a read-only filesystem, no capabilities and `no-new-privileges`.

## Install

Cal.diy must already be installed with `cal-docker-install.sh`.

```bash
bash OpenSource/Cal/scripts/cal-auto-cancel-install.sh
```

| Prompt | Answer |
|---|---|
| Domain of the Cal.diy install | `cal.example.com` |
| Install directory | Enter (`/var/www/docker/cal/<domain>`) |
| Question identifier | see below; the default is what Cal generates for the label above |
| Cancel when the answer is greater than | Enter (`14`) |
| Reason | Enter (the text above) |

It prints a **webhook secret** at the end. Then, inside Cal.diy:

**Event types → Interview → Webhooks tab → New webhook** (the event type's own tab, so only that event type is checked)

| Field | Value |
|---|---|
| Subscriber URL | `http://auto-cancel:8787` |
| Event triggers | **Booking created**, and **Booking requested** if the event type needs confirmation |
| Secret | the one the installer printed |
| Enable webhook | on |

(`Settings → Developer → Webhooks → Add webhook` also works, but that webhook fires for **every** event type of the user.)

### The question

**Event type → Advanced → Booking questions → Add a question → Number.** The type must be **Number**. Mark it required.

The receiver finds the answer by the question's **Identifier** (open the question to see it). Cal fills it in from the label by turning every character that is not a letter, digit, `-` or `_` into `-` and dropping trailing dashes:

```
What is your expected hourly rate ($ USD)?   ->   What-is-your-expected-hourly-rate----USD
```

If you edited the Identifier, or changed the label, type the real one at the prompt.

## Change something

| To change | Do |
|---|---|
| The reason | Edit `<install-dir>/auto-cancel/reason.txt`. Read on every cancellation, **no restart**. `{value}` and `{max}` are replaced by the answer and the limit. |
| The limit or the question | Re-run `cal-auto-cancel-install.sh`. The webhook secret is kept, so the webhook in Cal stays valid. Cal and its database are not restarted. |
| Another event type | Add a webhook on that event type's Webhooks tab. It must have a question with the **same Identifier**. |

Re-running the installer also picks up a newer `cal-auto-cancel.py` after a `git pull`.

## Check it works

Book the event once with a rate of `15` (a throwaway email), then:

```bash
cd /var/www/docker/cal/<domain>
docker compose logs -f auto-cancel
```

You should see `<uid>: 15 > 14, cancel -> HTTP 200 ...`, and the booking is cancelled with the reason.

## Behaviour

- **Strictly greater than.** 14 is kept, 14.01 is cancelled.
- **Two emails.** The attendee first gets the normal confirmation, then the cancellation (with the reason and a calendar cancel) a few seconds later.
- **Left alone, never cancelled:** an empty answer, text, `nan`, or a missing question. A leading `$` is accepted (`$20` counts as 20).
- **Not covered** (Cal refuses the cancel, the booking stays, the log says why):
  - seated event types: `HTTP 401 {"message":"User not a host of this event"}`
  - event types with cancelling disabled: `HTTP 400 {"message":"This event type does not allow cancellations"}`
  - bookings that have already ended
- **Rate limit.** Cal limits cancellations to 10 per minute per IP. Only matters if more than 10 over-limit bookings arrive in one minute.
- **Requests are signed.** Anything without a valid `X-Cal-Signature-256` is rejected with 401.

## Troubleshooting

`docker compose logs auto-cancel` (from the install directory). Nothing in the log after a booking means Cal never called the receiver: check the webhook exists, is enabled, is on the right event type and has the right trigger.

| Log line | Meaning |
|---|---|
| `rejected a request with a bad signature ...` | The webhook's Secret in Cal differs from `WEBHOOK_SECRET` in `auto-cancel.env`. Re-enter it. |
| `no usable number in 'X', left alone (answers in this booking: [...])` | The Identifier is wrong, or the question was not answered. Pick the right key from the list and re-run the installer. |
| `<uid>: 12 <= 14, kept` | Working; the answer is within the limit. |
| `cancel -> HTTP 200` | Cancelled. |
| `cancel -> HTTP 401 / 400 ...` | Cal refused. See *Not covered* above. |
| `but the cancel failed: URLError(...)` | The receiver cannot reach Cal. Check `docker compose ps`. |
| container exits at start with `the cancellation reason is empty` | `reason.txt` is empty. Write a reason in it. |

## Uninstall

```bash
bash OpenSource/Cal/scripts/cal-auto-cancel-uninstall.sh
```

Stops and deletes the container, deletes the three items above (the override file only if the installer made it), and removes the Python image if nothing else uses it. Cal.diy, its database and all bookings are not touched.

**Then delete the webhook inside Cal.diy** (event type → Webhooks tab). The script cannot do it, and until it is gone Cal tries `http://auto-cancel:8787` on every booking and the call fails.

## Verified

Run against a real Cal.diy (`main` @ `54343aa`) installed with `cal-docker-install.sh`, with a local SMTP server capturing Cal's emails:

| Case | Result |
|---|---|
| Answer 12, 14 | kept |
| Answer 14.5, 20 | cancelled; the attendee's email reads "Reason for cancellation: ..." and carries a calendar cancel |
| Event type that needs confirmation (Booking requested) | cancelled |
| Seated event type | Cal refuses (401), booking stays |
| Cancelling disabled | Cal refuses (400), booking stays |
| Edit `reason.txt` | next cancellation uses it, no restart |
| Re-run installer | secret kept; Cal and database not restarted |

The receiver was also tested against a mock Cal (forged signature, garbage body, `nan`/`inf`/text answers, Cal down, Cal refusing the cancel), and the installer and uninstaller against a stand-in Compose project.

**Not tested:** on a VPS; clicking through the Webhooks form in Cal's web UI (the webhook was created through Cal's own webhook API, which runs the same validation); a Jitsi location (a plain link location was used); bookings that have already ended; the 10-per-minute limit.
