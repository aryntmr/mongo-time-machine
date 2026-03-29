# Problem Statement: MongoDB Time Travel Infrastructure

## What You're Building

A data infrastructure pipeline that enables "time travel" queries on a MongoDB collection. Jason has a MongoDB collection with two fields — `name` (stock/company name) and `price` (current price). Prices are updated in place with no history, no timestamps, no transactional records. The pipeline should connect to this database and store historical data on a separate GCP data store so that Jason can query the exact price of any stock at any arbitrary point in time.

## Core Requirements (Directly from Jason)

- **Do not modify the source MongoDB database** — "We don't want to make any changes to this database. This database stays the same."
- **All infrastructure must be on GCP** — "Let's try to do this everything here in GCP because that's what we use."
- **Not AWS** — "If we do it in AWS I think there might be something that makes it too easy."
- **Exact accuracy** — "I want the exact price at that exact moment. I don't want to get approximate answer."
- **As granular as possible** — "I want this to be as granular as possible" (said in response to Aryan suggesting reading every minute).
- **Arbitrary time range** — "We want to do this arbitrary time travel on this data for any given time."
- **No analytics** — "This is a data infrastructure project. It's not an analytics project." (said twice)
- **Not theoretical** — "This is not a theoretical analysis."

## What Jason Will Provide

Nothing. "Will you give me any template code or database? — No, nothing."

## Deliverable (Directly from Jason)

- **Working setup instructions** — "When we meet together, you can tell me exactly what I need to set up to make the time travel work."
- **Step-by-step process** — "We can go through step by step in terms of okay how do I set it up in GCP, what are other things I need to do."
- **He follows the instructions himself** — "I should be able to follow your instruction and set that up."
- **Scripts if needed** — "If you have additional scripts, feel free to share that with me as well."
- **It must work on his database** — "When we meet together, we're going to try this on this database."

## Key Quotes from Jason (With Context)

- **"I don't think you need any permissions from me in terms of the data access."**
  → Said at the very start. You don't need anything from Jason to do this project. You build and test everything independently.

- **"Feel free to use any AI tools you want for the take-home, but when you're ready to present, you cannot use AI. You do have to understand everything yourself."**
  → AI-assisted building is allowed. During the presentation, Jason will ask questions and you must answer from your own understanding.

- **"Have your phone joining the meeting so that I can have another view of your screen."**
  → During the presentation meeting, Jason wants a second camera angle to see your screen while you talk through the solution.

- **"Everything is update in place. The database doesn't have transactional records. We don't have timestamps either."**
  → The source MongoDB overwrites prices directly. There is no built-in history, no audit trail, no changelog, no timestamps stored in the database.

- **"Someone is writing to this database but they're not going to keep a trail of everything they do."**
  → There is an existing application writing to MongoDB. It does not keep any historical record of writes. You have no control over this application.

- **"There's no particular cadence on when those prices will change."**
  → Updates are not periodic. Prices can change at any time with no fixed interval.

- **"We don't want to make any changes to this database. This database stays the same."**
  → Do not modify the MongoDB schema, data, or application logic.

- **"We want to have an interface that works on potentially another data store. Probably an offline data store."**
  → The historical data should live in a separate data store on GCP, not inside the source MongoDB. Jason used the words "offline data store."

- **"Let's try to do this everything here in GCP because that's what we use."**
  → GCP only. This is what the company uses internally.

- **"If we do it in AWS I think there might be something that makes it too easy."**
  → Jason wants to see engineering depth in the solution, not just a turnkey managed service.

- **"We're going to talk through some of the engineering architecture, design choices, why this technology versus the other one, tradeoff, is this scalable."**
  → The presentation includes discussion of architecture decisions, technology choices, tradeoffs, and scalability. Jason will ask "why this and not that."

- **"When we meet together, we're going to try this on this database and you can tell me exactly what I need to set up."**
  → The presentation is a live walkthrough on Jason's actual database. Your instructions must work when he follows them.

- **"I should be able to follow your instruction and set that up, and if you have additional scripts, feel free to share."**
  → Instructions must be clear enough for Jason to follow directly. Provide scripts to automate setup where possible.

- **"You don't have control in terms of how data gets into this database. You're more like setting up a listener, setting up some monitoring on this."**
  → Jason's own words for the role of your pipeline. You are a listener/monitor on his database. You do not control or influence the writes.

- **"I want this to be as granular as possible. I want this to be very accurate."**
  → Said when Aryan suggested reading every minute. Jason pushed back — he wants maximum granularity, not periodic reads that lose intermediate changes.

- **"When I say I want this at 12:05.53 seconds, I don't want to get the data that's stale. I don't want to get the data that's from 12:04. I want the exact price at that exact moment."**
  → The query for a specific timestamp must return the exact price at that time, not data from an earlier time.

- **"This is a data infrastructure project. It's not an analytics project."**
  → Repeated twice at the end of the call for emphasis. No dashboards, charts, or analysis. Pipeline and query interface only.

- **"This is not a theoretical analysis. When we meet again I would expect you tell me exactly how to set this up."**
  → Do not present only a design document. You must have a working, deployable system with concrete setup steps.

- **"Will you give me any template code or database? — No, nothing."**
  → You are fully on your own. Everything from scratch.

- **"Should be pretty straightforward. Should be something that you could do on your end."**
  → Jason considers this a reasonably scoped project.

- **"I don't know how familiar you are with MongoDB, but if you don't, I think this will be options to learn."**
  → MongoDB expertise is not assumed. Learning it as part of the project is expected.

- **"Can you set up the pipeline so that this works?"**
  → Jason's one-sentence summary of the entire project.

## What "Time Travel Query" Means (From Jason's Own Example)

Jason's example: "Right now the Apple price is 114. When they change it, they just change it to 117. So the question I want to ask is: what was the price of Apple at 12:04? And the answer should be 114 instead of 117."

Given a stock name and a timestamp, return the price that was in the database at that moment in time.

## Constraints Directly Stated by Jason

- The source database has no timestamps — it only stores current name and price.
- Updates are in place — previous values are overwritten, not preserved.
- There is no fixed cadence for updates — prices change erratically.
- You are a listener/monitor — you don't control the writes to the database.
- The source database must not be modified.
- Everything must be on GCP.
- The deliverable must be working infrastructure, not a theoretical design.
