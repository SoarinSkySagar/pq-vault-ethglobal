# Experiment results

{'seeds': 20, 'h': 7, 'q_max': 128, 'fors': 'JARDIN plain FORS k=32 a=4', 'runtime_s': 596.5}

## crash

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 9 | 36.4 | 467 | 33.8 | 36.4 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 9 | 36.4 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 9 | 36.4 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 4.5 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 4.5 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 4.5 | 0 | 0 | 0 |

## stale_backup_silent

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |

## stale_backup_known

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| reslot | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| reslot | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| anchored | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |

## lost_state

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 2 | 96.0 | 300 | 15 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 2 | 96.0 | 300 | 15 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 15 | 0 |
| fallback | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 15 | 0 |
| fallback | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 15 | 0 |
| reslot | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| reslot | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| reslot | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 1 |
| anchored | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |

## clone

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 2 | 96.0 | 380 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 2 | 96.0 | 0 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 0 | 0 | 1 | 0 | 2 |
| durable | False | 2 | 96.0 | 380 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 2 | 96.0 | 0 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 0 | 0 | 1 | 0 | 2 |
| fallback | False | 2 | 96.0 | 380 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 2 | 96.0 | 0 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 0 | 0 | 1 | 0 | 2 |
| reslot | False | 2 | 96.0 | 380 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 2 | 96.0 | 0 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 0 | 0 | 1 | 0 | 2 |
| anchored | False | 2 | 96.0 | 380 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 2 | 96.0 | 0 | 20 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 0 | 0 | 1 | 0 | 2 |
| anchored_w1 | False | 2 | 96.0 | 200 | 20 | 96.0 | 25 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 2 | 96.0 | 0 | 10 | 96.0 | 25 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 2 | 96.0 | 0 | 1 | 96.0 | 25 | 0 | 1 | 0 | 2 |

## rollback

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 3 | 78.5 | 420 | 35 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 3 | 78.5 | 420 | 35 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 3 | 78.5 | 420 | 35 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | False | 3 | 78.5 | 420 | 35 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 3 | 78.5 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |

## rollback_inflight

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 3 | 77.9 | 211 | 39 | 77.9 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 3 | 77.9 | 0 | 11.4 | 79.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 3 | 78.5 | 0 | 5.1 | 96.0 | 0 | 0 | 5.1 | 0 | 5.1 |
| durable | False | 3 | 77.9 | 211 | 39 | 77.9 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 3 | 77.9 | 0 | 11.4 | 79.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 3 | 78.5 | 0 | 5.1 | 96.0 | 0 | 0 | 5.1 | 0 | 5.1 |
| fallback | False | 3 | 77.9 | 211 | 39 | 77.9 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 3 | 77.9 | 0 | 11.4 | 79.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 3 | 78.5 | 0 | 5.1 | 96.0 | 0 | 0 | 5.1 | 0 | 5.1 |
| reslot | False | 3 | 77.9 | 211 | 39 | 77.9 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 3 | 77.9 | 0 | 11.4 | 79.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 3 | 78.5 | 0 | 5.1 | 96.0 | 0 | 0 | 5.1 | 0 | 5.1 |
| anchored | False | 3 | 78.5 | 173 | 39 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 3 | 78.5 | 0 | 15.3 | 78.5 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 2 | 96.0 | 0 | 5.35 | 96.0 | 0 | 0 | 5.35 | 0 | 5.35 |
| anchored_w1 | False | 2 | 96.0 | 64 | 37.75 | 96.0 | 21.85 | 2.95 | 0 | 0 | 0 |
| anchored_w1 | True | 2 | 96.0 | 0 | 8.5 | 96.0 | 21.85 | 2.95 | 0 | 0 | 0 |
| anchored_w1 | revoke | 2 | 96.0 | 0 | 2.75 | 96.0 | 21.3 | 3.9 | 2.75 | 0 | 2.75 |

## lying_host

| policy | ledger | worst_gamma | worst_min_bits | total_double_accepted | mean_exposure_steps | worst_exposure_bits | mean_refused | mean_retires | mean_revocations | mean_stateless | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|---|---|
| naive | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| naive | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| naive | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| durable | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| durable | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| fallback | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| reslot | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | False | 2 | 96.0 | 200 | 10 | 96.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | True | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored | revoke | 2 | 96.0 | 0 | 0 | 128.0 | 0 | 0 | 0 | 0 | 0 |
| anchored_w1 | False | 1 | 128.0 | 0 | 0 | 128.0 | 29 | 0 | 0 | 0 | 0 |
| anchored_w1 | True | 1 | 128.0 | 0 | 0 | 128.0 | 29 | 0 | 0 | 0 | 0 |
| anchored_w1 | revoke | 1 | 128.0 | 0 | 0 | 128.0 | 29 | 0 | 0 | 0 | 0 |

