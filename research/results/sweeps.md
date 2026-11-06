# Sensitivity sweeps (10 seeds)

## repeated_restore

| value | policy | ledger | worst_gamma | worst_min_bits | expected_bits_at_worst_gamma | total_double_accepted | mean_exposure_steps | mean_refused | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|
| 1 | durable | False | 2 | 96.0 | 97.5 | 50 | 5 | 0 | 0 |
| 1 | durable | True | 2 | 96.0 | 97.5 | 0 | 0 | 0 | 0 |
| 1 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 1 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 2 | durable | False | 3 | 78.5 | 80.2 | 100 | 10 | 0 | 0 |
| 2 | durable | True | 3 | 78.5 | 80.2 | 0 | 0 | 0 | 0 |
| 2 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 2 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 4 | durable | False | 5 | 57.2 | 59.5 | 200 | 20 | 0 | 0 |
| 4 | durable | True | 5 | 57.2 | 59.5 | 0 | 0 | 0 | 0 |
| 4 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 4 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 8 | durable | False | 9 | 35.6 | 37.8 | 400 | 40 | 0 | 0 |
| 8 | durable | True | 9 | 35.6 | 37.8 | 0 | 0 | 0 | 0 |
| 8 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 8 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |

## rollback_depth

| value | policy | ledger | worst_gamma | worst_min_bits | expected_bits_at_worst_gamma | total_double_accepted | mean_exposure_steps | mean_refused | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|
| 1 | durable | False | 2 | 96.0 | 97.5 | 70 | 35 | 0 | 0 |
| 1 | durable | True | 2 | 96.0 | 97.5 | 0 | 0 | 0 | 0 |
| 1 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 1 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 2 | durable | False | 2 | 96.0 | 97.5 | 140 | 35 | 0 | 0 |
| 2 | durable | True | 2 | 96.0 | 97.5 | 0 | 0 | 0 | 0 |
| 2 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 2 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 3 | durable | False | 3 | 78.5 | 80.2 | 210 | 35 | 0 | 0 |
| 3 | durable | True | 3 | 78.5 | 80.2 | 0 | 0 | 0 | 0 |
| 3 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 3 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 5 | durable | False | 8 | 39.4 | 41.9 | 350 | 35 | 0 | 0 |
| 5 | durable | True | 8 | 39.4 | 41.9 | 0 | 0 | 0 | 0 |
| 5 | anchored_w1 | True | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |
| 5 | anchored_w1 | revoke | 1 | 128.0 | 128.0 | 0 | 0 | 0 | 0 |

## clones

| value | policy | ledger | worst_gamma | worst_min_bits | expected_bits_at_worst_gamma | total_double_accepted | mean_exposure_steps | mean_refused | mean_reslots |
|---|---|---|---|---|---|---|---|---|---|
| 2 | durable | False | 2 | 96.0 | 97.5 | 240 | 25 | 0 | 0 |
| 2 | durable | True | 2 | 96.0 | 97.5 | 0 | 25 | 0 | 0 |
| 2 | anchored_w1 | True | 2 | 96.0 | 97.5 | 0 | 12 | 28 | 0 |
| 2 | anchored_w1 | revoke | 2 | 96.0 | 97.5 | 0 | 1 | 28 | 2 |
| 3 | durable | False | 3 | 77.3 | 80.2 | 480 | 25 | 0 | 0 |
| 3 | durable | True | 3 | 77.3 | 80.2 | 0 | 25 | 0 | 0 |
| 3 | anchored_w1 | True | 3 | 77.9 | 80.2 | 0 | 12 | 41 | 0 |
| 3 | anchored_w1 | revoke | 3 | 78.5 | 80.2 | 0 | 1 | 41 | 3 |
| 4 | durable | False | 4 | 65.7 | 68.3 | 720 | 25 | 0 | 0 |
| 4 | durable | True | 4 | 65.7 | 68.3 | 0 | 25 | 0 | 0 |
| 4 | anchored_w1 | True | 4 | 66.1 | 68.3 | 0 | 12 | 54 | 0 |
| 4 | anchored_w1 | revoke | 4 | 66.5 | 68.3 | 0 | 1 | 54 | 4 |

