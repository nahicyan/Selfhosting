# Cal.diy Auto-Cancel

Cancels a booking automatically, with a stated reason, when the answer to a **number question** is above a limit. Cal.diy has no such setting (no Workflows in this fork, and a Number question has no maximum), so a small receiver runs next to it.

Someone cancelled this way is **remembered by email**: if they book again, that booking is cancelled too, with a second reason, whatever they answer this time.

Current setup (the Interview event type):

| | |
|---|---|
| Question | `What is your expected hourly rate ($ USD)?` |
| Cancel when | answer **> 14** (14 is kept, 14.01 is cancelled) |
| Reason emailed | `Sorry, you are unaffordable for us. But we wish you best of luck. Thank you.` |
| Reason for a repeat application | `Sorry, we have already reviewed your application and cannot consider another one. We wish you the best of luck. Thank you.` |

# ==⛔ Needs SMTP configured in Cal's `.env` — the reasons are delivered by email ⛔==
# ==⛔ Seated event types and event types with "disable cancelling" cannot be auto-cancelled ⛔==
# ==⛔ Test bookings count: a test email cancelled for its answer is blocked afterwards (see Repeat applicants) ⛔==

## How it works

```
booking made
  -> Cal.diy sends a signed webhook (Booking created / Booking requested)
  -> auto-cancel container checks the signature
  -> email was cancelled before?  cancel with the repeat reason
  -> answer above the limit?      cancel with the reason, and remember the email
  -> Cal.diy cancels the booking (through its own /api/cancel) and emails the reason to the attendee
```

The receiver runs as one more service in the existing Cal.diy Compose project. Cal.diy reaches it at `http://auto-cancel:8787` and it reaches Cal.diy at `http://calcom:3000`, both on the project's private network. **Nothing is published on the host**, so it needs no Nginx block and no certificate.

## Files

All in `OpenSource/Cal/scripts/`:

| File | What it is |
|---|---|
| `cal-auto-cancel.py` | The receiver. Runs all the time in the container and does the cancelling. |
| `cal-auto-cancel-install.sh` | Setup and upgrade: asks the questions, writes the config, starts the container. Safe to re-run. |
| `cal-auto-cancel-uninstall.sh` | Stops the container and removes everything the installer added. |

What the installer adds to the Cal install directory (`/var/www/docker/cal/<domain>` by default). It does not touch `docker-compose.yml` or `.env`:

```
docker-compose.override.yml   the auto-cancel service (Compose merges it automatically,
                              so the usual `docker compose up -d` includes it)
auto-cancel.env               WEBHOOK_SECRET, FIELD, MAX_VALUE   (mode 600)
auto-cancel/                  mounted read-only into the container
  cal-auto-cancel.py            the receiver
  reason.txt                    the cancellation reason
  reason-repeat.txt             the reason for someone who books again
auto-cancel-data/             mounted read-write: the receiver's memory
  rejected.txt                  one email per line, everyone it has cancelled
```

The container runs `python:3.13-slim` with a read-only filesystem, no capabilities and `no-new-privileges`. It runs as the user who ran the installer (so `rejected.txt` is yours to edit without sudo), or as `nobody` if the installer was run as root. `auto-cancel-data/` is the only place it can write.

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
| Reason for a repeat application | Enter (the text above) |

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

## Upgrade an existing install

Installed it before the repeat-applicant block existed? Update it in place:

```bash
git pull
bash OpenSource/Cal/scripts/cal-auto-cancel-install.sh
```

Answer the domain and directory, then **press Enter at every other prompt**. On a re-run the current settings are the defaults, so your limit, question and reasons are kept (including any edit you made to `reason.txt`), and the existing webhook secret is kept. It then:

- adds `reason-repeat.txt` and the `auto-cancel-data/` folder,
- rewrites `docker-compose.override.yml` and recreates only the `auto-cancel` container (Cal and its database are not restarted),
- leaves the webhook in Cal.diy alone: same URL, same secret, nothing to redo there.

**Earlier rejections were not recorded**, so those people can still book once more. Add them to `rejected.txt` (next section).

## Repeat applicants

Everyone the receiver cancels for their answer is added to `<install-dir>/auto-cancel-data/rejected.txt`:

```
rate.twenty@applicant.test  # 2026-10-08, answered 20
```

A later booking from the same person is cancelled with the repeat reason, **whatever they answer this time**, including a rate under the limit.

- **Same person = same email, compared loosely.** Lowercased, without a `+tag` (`a+job@x.com` is `a@x.com`), and without dots for Gmail (`J.Smith@gmail.com` is `jsmith@googlemail.com`).
- **Only people it cancelled are blocked.** Someone who was kept (answer within the limit) can book again freely. Rescheduling through Cal's reschedule link is not counted as a new application.
- **Only a cancel that really happened is remembered.** If Cal refuses the cancel (seated event, cancelling disabled), that email is not added.
- **It is a deterrent, not a lock.** Someone who applies from a different email gets through. Cal does not give the applicant's IP, and matching on name would catch people who share one.

### Edit the list

`rejected.txt` is plain text and is re-read on every booking, so **no restart** is needed. One email per line; anything after a `#` is a note; blank lines are ignored.

- **Add someone** (for example a person rejected before the upgrade): add a line with their email.
- **Let someone book again:** delete their line.

### Test bookings are remembered too

Booking with a test email and an answer above the limit adds that email to the list, and the next test booking from it is cancelled with the repeat reason. **Delete your test emails from `rejected.txt` afterwards.** Using `you+test1@…` and `you+test2@…` does not help: a `+tag` counts as the same person.

### Add the people rejected before the upgrade

The cancelled bookings are still in Cal's database. This lists the emails of bookings cancelled with your reason and appends them (use your own reason text; it contains no single quote):

```bash
cd /var/www/docker/cal/<domain>
docker compose exec -T database psql -U calcom -d calendso -At -c \
  "select distinct lower(a.email) from \"Booking\" b join \"Attendee\" a on a.\"bookingId\" = b.id where b.status = 'cancelled' and b.\"cancellationReason\" = 'Sorry, you are unaffordable for us. But we wish you best of luck. Thank you.' order by 1;" \
  >> auto-cancel-data/rejected.txt
```

Then open the file and **delete your own test emails** and any extra guests that were on those bookings. (`calcom` and `calendso` are the database user and name `cal-docker-install.sh` sets up.)

## Change something

| To change | Do |
|---|---|
| The reason | Edit `<install-dir>/auto-cancel/reason.txt`. Read on every cancellation, **no restart**. `{value}` and `{max}` are replaced by the answer and the limit. |
| The repeat reason | Edit `<install-dir>/auto-cancel/reason-repeat.txt`. Same: no restart. |
| Who is blocked | Edit `<install-dir>/auto-cancel-data/rejected.txt` (see above). No restart. |
| The limit or the question | Re-run `cal-auto-cancel-install.sh` and change that prompt. The webhook secret and the rejected list are kept, so the webhook in Cal stays valid. Cal and its database are not restarted. |
| Another event type | Add a webhook on that event type's Webhooks tab. It must have a question with the **same Identifier**. The rejected list is shared by every event type that uses this receiver. |

Re-running the installer also picks up a newer `cal-auto-cancel.py` after a `git pull`.

## Check it works

Book the event once with a rate of `15` (a throwaway email), then:

```bash
cd /var/www/docker/cal/<domain>
docker compose logs -f auto-cancel
```

You should see `<uid>: 15 > 14, cancel -> HTTP 200 ...` and `remembered <email> ...`, and the booking is cancelled with the reason. Book again with the same email and any rate: it is cancelled with the repeat reason. Then remove that email from `rejected.txt`.

## Behaviour

- **Strictly greater than.** 14 is kept, 14.01 is cancelled.
- **Two emails.** The attendee first gets the normal confirmation, then the cancellation (with the reason and a calendar cancel) a few seconds later. This is the same for a repeat application.
- **Left alone, never cancelled:** an empty answer, text, `nan`, or a missing question (unless the email is on the rejected list). A leading `$` is accepted (`$20` counts as 20).
- **Not covered** (Cal refuses the cancel, the booking stays, the log says why):
  - seated event types: `HTTP 401 {"message":"User not a host of this event"}`
  - event types with cancelling disabled: `HTTP 400 {"message":"This event type does not allow cancellations"}`
  - bookings that have already ended
- **Rate limit.** Cal limits cancellations to 10 per minute per IP. Only matters if more than 10 cancellations arrive in one minute.
- **Requests are signed.** Anything without a valid `X-Cal-Signature-256` is rejected with 401.

## Troubleshooting

`docker compose logs auto-cancel` (from the install directory). Nothing in the log after a booking means Cal never called the receiver: check the webhook exists, is enabled, is on the right event type and has the right trigger.

| Log line | Meaning |
|---|---|
| `rejected a request with a bad signature ...` | The webhook's Secret in Cal differs from `WEBHOOK_SECRET` in `auto-cancel.env`. Re-enter it. (After an uninstall and a fresh install the secret is new: update it in Cal.) |
| `no usable number in 'X', left alone (answers in this booking: [...])` | The Identifier is wrong, or the question was not answered. Pick the right key from the list and re-run the installer. |
| `<uid>: 12 <= 14, kept` | Working; the answer is within the limit. |
| `<uid>: 20 > 14, cancel -> HTTP 200` | Cancelled for the answer. |
| `<uid>: <email> was cancelled before, repeat application, cancel -> HTTP 200` | A repeat application, cancelled with the repeat reason. |
| `remembered <email>: ...` | Added to `rejected.txt`. |
| `could not remember ...` / `could not read ...` | `auto-cancel-data/` is not writable / readable by the container's user. Re-run the installer. A list that cannot be read is skipped; the normal rules still apply. |
| `cancel -> HTTP 401 / 400 ...` | Cal refused. See *Not covered* above. |
| `but the cancel failed: URLError(...)` | The receiver cannot reach Cal. Check `docker compose ps`. |
| container exits at start with `the cancellation reason is empty` | `reason.txt` or `reason-repeat.txt` is empty. Write a reason in it. |
| container exits at start with `PermissionError ... /data/rejected.txt` | `auto-cancel-data/` is owned by someone else. Re-run the installer as the same user that owns the install. |

## Uninstall

```bash
bash OpenSource/Cal/scripts/cal-auto-cancel-uninstall.sh
```

Stops and deletes the container, deletes the install files (the override file only if the installer made it), and removes the Python image if nothing else uses it. If the rejected list has entries it asks **Keep the list?**: say yes and `auto-cancel-data/` stays, so a later reinstall remembers those people. Cal.diy, its database and all bookings are not touched.

**Then delete the webhook inside Cal.diy** (event type → Webhooks tab). The script cannot do it, and until it is gone Cal tries `http://auto-cancel:8787` on every booking and the call fails. A reinstall makes a new webhook secret, so a kept webhook needs its Secret updated to the one the installer prints.

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
| Rejected applicant books again with a lower rate | cancelled with the repeat reason (the attendee's email shows it) |
| Same, with `+tag`, upper case, Gmail dots or `googlemail.com` | cancelled with the repeat reason |
| Someone else, and someone kept earlier, booking again | kept |
| Hand-added line in `rejected.txt` blocks; deleting it unblocks | works with no restart |
| Container restarted, installer re-run | the rejected list survives |
| Upgrade over a copy of the previous deployment (custom limit 16, custom `reason.txt`) | Enter at every prompt kept the limit, the reason and the secret; the existing webhook kept working; Cal and its database were not restarted |
| Uninstall with and without keeping the list; reinstall with a kept list | works; after the reinstall the webhook needed the new secret |
| Re-run installer | Cal and database not restarted |

The receiver was also tested against a mock Cal (forged signature, garbage body, `nan`/`inf`/text answers, Cal down, Cal refusing the cancel, an unreadable or unwritable rejected list, an email only in `attendees[]`, a booking with no email at all, a refused cancel not being remembered), and the installer and uninstaller against a stand-in Compose project.

**Not tested:** on your VPS (the upgrade was tried on a rebuilt copy of the previous deployment, not the live one); clicking through the Webhooks form in Cal's web UI (the webhook was created through Cal's own webhook API, which runs the same validation); installing as root (only the generated config was checked, with a stubbed `id` and `chown`); a Jitsi location (a plain link location was used); bookings that have already ended; the 10-per-minute limit.
