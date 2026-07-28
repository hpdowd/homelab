# Revision Guide: Editing Model Prose Toward Human Register

## 1. Priority operations

These ten changes move a draft furthest per unit of editing effort. If the pass is cut short, everything below this table is optional and everything in it is not. Ranks are ordered by leverage, not by how often the pattern occurs.

| Rank | ID | Operation | Why it ranks here |
|---|---|---|---|
| 1 | S3 | Break participial result clauses (`, allowing`, `, ensuring`, `, making it`) into main clauses or cut them | The single densest marker in model prose. Each fix is mechanical and each one changes the shape of a sentence. |
| 2 | C1 | Delete stock metadiscourse (`it is important to note`, `it is worth mentioning`) and let the claim stand alone | Costs one deletion and removes nothing a reader needed. |
| 3 | S2 | Recast `not just X, it's Y` as a direct claim about Y | Rare in human prose, near-compulsive in model prose, instantly recognisable. |
| 4 | S4 | Widen sentence-length variance until at least one sentence per paragraph is markedly shorter than its neighbours | Detectable statistically and audible to a reader. Cheap to fix by joining and splitting. |
| 5 | T1 | Convert most em dashes to full stops, semicolons, commas, or brackets, keeping a few | The most publicly known marker. One edit each. |
| 6 | L1 | Swap inflated verbs (`delve`, `leverage`, `underscore`, `showcase`) for the plain verb | The only lexical family with published frequency evidence. |
| 7 | S1 | Convert three-item lists to two or four items, or subordinate one item to another | Model prose reaches for three almost every time it lists anything. |
| 8 | P3 | Delete the sentence or paragraph that summarises what the section just said | Removes text rather than adding it, and removes the most redundant text in the draft. |
| 9 | I1 | Move or drop sentence-initial connectives (`Moreover`, `Furthermore`, `Additionally`, `Ultimately`) | High frequency, and the fix is deletion in most cases. |
| 10 | R1 | State a position where the draft weighs two sides and declines to choose | Changes what the text says, not just how it sounds, which is why it is worth the effort despite costing more than the other nine. |

Two operations sit just under the line and are worth doing when time allows: T2 (converting bulleted fragments back to prose, where the medium is prose) and P2 (cutting the opening paragraph that announces what the piece will cover).

---

## 2. Lexical choices

### L1. Inflated verbs

| Field | Content |
|---|---|
| Pattern | Verbs that raise the register above the subject matter: `delve`, `leverage`, `utilise`, `underscore`, `highlight`, `showcase`, `foster`, `facilitate`, `harness`, `unlock`, `navigate` used of anything that is not a boat, `craft` used of anything that is not made by hand. |
| Replace with | Use the verb that names the action. `Utilise` becomes `use`, `underscore` becomes `shows` or nothing at all, `facilitate` becomes the thing that was actually done. Where the inflated verb is standing in for a missing specific, supply the specific. |
| Target frequency | Kobak and colleagues' 2024 analysis of excess vocabulary in PubMed abstracts found sharp post-2023 rises in `delves`, `underscores`, `showcasing`, `intricate`, `pivotal`, and `realm`. Their baseline is scientific abstracts rather than general prose, so the numbers transfer only as direction. In general nonfiction these verbs appear, but rarely more than once or twice in a thousand words, and rarely two of them in the same paragraph. |
| Over-correction failure | Prose flattened to a monosyllabic core vocabulary, which reads as machine-generated in a different way. "The paper looks at how the thing works and shows the way it does the job" is worse than the sentence it replaced. Keep the Latinate verb when it is the accurate one; `mitigate` and `attenuate` mean things that `reduce` does not. |
| Confidence | Measured, with the corpus caveat above. |

| Before | After |
|---|---|
| This section delves into the mechanisms that underpin monetary transmission and showcases how rate changes propagate to household borrowing. | This section works through how a rate change reaches household borrowing, which takes about eighteen months and less of it than the models predict. |
| We leveraged the existing ingest pipeline to facilitate faster onboarding of new tenants. | We reused the ingest pipeline, so a new tenant comes online in a day instead of a week. |

### L2. Evaluative adjective inflation

| Field | Content |
|---|---|
| Pattern | Adjectives that assert importance instead of demonstrating it: `crucial`, `vital`, `essential`, `pivotal`, `robust`, `comprehensive`, `seamless`, `significant`, `profound`, `key`. They cluster, and they attach to nouns that have not earned them. |
| Replace with | Give the fact that made you reach for the adjective. If a component is crucial, say what breaks without it. If a framework is comprehensive, say what it covers. Where no such fact is available, delete the adjective and leave the noun bare. |
| Target frequency | I cannot give a defensible number. These words are ordinary English and appear throughout good nonfiction; the marker is density and the absence of supporting detail, not the words themselves. Treat two in one paragraph as a prompt to check whether either is doing work. |
| Over-correction failure | Adjective-stripped prose that refuses to evaluate anything, so the reader has to infer what matters from ordering alone. A guide that describes twelve configuration options in identical neutral terms has hidden the two that will cause an outage. |
| Confidence | Observed. |

| Before | After |
|---|---|
| This robust and comprehensive framework provides a seamless experience and delivers significant improvements in several key areas. | The framework covers the whole ingest path and cut our median latency by a third. Nobody has had to touch it since March. |
| Sourcing high-quality, sustainably harvested vanilla is absolutely crucial to the final product. | Vanilla is the most expensive thing in the recipe and the easiest to get wrong, because most of what is sold as extract has been cut with vanillin. |

### L3. Nominalisation

| Field | Content |
|---|---|
| Pattern | Actions buried in abstract nouns, usually with a weak verb carrying the sentence: `the implementation of`, `the establishment of`, `a reduction in`, `there is a requirement for`, `provides an improvement to`. |
| Replace with | Recover the verb and give it a subject that can act. `The implementation of X resulted in a reduction of Y` becomes `after X went in, Y fell`. Name who did the thing wherever the draft has hidden them. |
| Target frequency | Nominalisation is genuinely frequent in academic and legal writing and much rarer in journalism. Biber's register comparisons show the split clearly enough that no single target applies; calibrate to the genre rather than to a number. |
| Over-correction failure | Every abstract noun converted to a verb, producing a chain of short active clauses with no way to refer back to a process as a thing. Some concepts only exist as nouns, and `the migration` is easier to discuss across four paragraphs than `when we migrated` repeated four times. |
| Confidence | Measured for the register split, observed for the model-versus-human difference. |

| Before | After |
|---|---|
| The implementation of the new scheduling system resulted in a reduction of overtime expenditure across the ward. | After the new rota went in, the ward spent less on overtime. Not much less, but the trend held for a year. |
| There is a requirement for the verification of vendor certificates prior to the establishment of a connection. | Verify the vendor's certificate before you connect. |

### L4. Abstraction nouns standing in for content

| Field | Content |
|---|---|
| Pattern | Nouns that promise substance and defer it: `insights`, `considerations`, `aspects`, `elements`, `factors`, `dynamics`, `landscape`, `realm`, `space`, `journey`, `framework` used loosely, `tapestry` in any use at all. They cluster in opening and closing paragraphs. |
| Replace with | Name the thing. `Offers insights into container security` becomes the actual finding. `Several factors` becomes the two or three factors, listed. Where you cannot name them, the sentence has nothing in it and should go. |
| Target frequency | `Realm` and `landscape` show up in the PubMed excess-vocabulary results, so there is evidence for those two. For the rest I have no counts. The usable test is not frequency but substitutability: if the sentence survives deleting the noun phrase, it was a placeholder. |
| Over-correction failure | A draft that refuses to generalise and lists particulars where a category was the right unit, so the reader has to do the grouping. "We looked at nitrogen, phosphorus, potassium, sulphur, calcium, magnesium and iron levels" is worse than "we looked at soil nutrients" when the individual results are not discussed. |
| Confidence | Measured for two items, observed for the pattern. |

| Before | After |
|---|---|
| This piece offers insights into the evolving landscape of container security and explores key considerations for practitioners operating in this space. | This piece is about who can push an image your cluster will pull, and what happens on the day your registry credentials leak. |
| The report highlights several important factors and dynamics shaping the future of the industry. | The report names two things: the price of hafnium, and the fact that one Dutch company makes the machines. |

---

## 3. Stock collocations

### C1. Metadiscursive stock phrases

| Field | Content |
|---|---|
| Pattern | Fixed phrases that announce the status of a claim rather than making it: `it is important to note that`, `it is worth mentioning`, `it should be noted`, `in today's fast-paced world`, `plays a crucial role in`, `serves as a testament to`, `stands as`, `at its core`, `when it comes to`, `at the end of the day`. |
| Replace with | Let the sentence begin with its subject and carry its own emphasis. Where the phrase was flagging genuine importance, move the claim earlier in the paragraph instead, which is what a human writer does with material they want noticed. |
| Target frequency | No corpus count I can point to for the whole family. In edited general nonfiction these constructions appear occasionally, and almost never twice in a paragraph. One instance per thousand words is a defensible ceiling; zero is also fine here, which is unusual among these operations. |
| Over-correction failure | Loss of genuine hedging and attribution alongside the filler. `It should be noted that the sample excluded under-18s` is carrying real information about a limitation. Cut the phrase, keep the limitation. |
| Confidence | Observed. |

| Before | After |
|---|---|
| It is important to note that sourdough starters do not require commercial yeast. It is also worth mentioning that the wild yeast present on flour is generally sufficient. | A sourdough starter needs no commercial yeast. The wild yeast is already on the flour, and in a warm kitchen it will announce itself within three days. |
| In today's fast-paced digital landscape, it is crucial to understand that password reuse remains a significant risk. | Password reuse is still how most account takeovers begin. The attacker does not break anything; they log in. |

### C2. Stock metaphor and analogy

| Field | Content |
|---|---|
| Pattern | A small set of figures used regardless of subject: `double-edged sword`, `tip of the iceberg`, `shed light on`, `paint a picture`, `navigate the complexities`, `unlock the potential`, `a delicate balance`, `the backbone of`, `a perfect storm`. |
| Replace with | Describe the mechanism literally, which is usually shorter, or build a figure out of the subject matter itself. A metaphor drawn from the domain under discussion reads as authored; one drawn from the general pool reads as retrieved. |
| Target frequency | Varies too much to state. Idiom density is a house-style question, and good journalism uses far more of it than good technical writing. The marker is that model prose draws from a narrow shared pool, not that it uses figures at all. |
| Over-correction failure | Metaphor stripped out entirely, leaving prose that explains abstract relations with no concrete image anywhere. This is a real cost: the figure was often the only thing making the paragraph comprehensible. |
| Confidence | Observed. |

| Before | After |
|---|---|
| Encryption is a double-edged sword, and the ongoing debate over lawful access is merely the tip of the iceberg. | Encryption protects the same message whoever sends it. That is the whole of the lawful-access argument, and it is why the argument never resolves. |
| This study sheds light on the complex tapestry of gut microbiome interactions. | The study followed eleven bacterial species through a course of antibiotics. Three of them never came back. |

---

## 4. Sentence-internal syntax

### S1. The obligatory tricolon

| Field | Content |
|---|---|
| Pattern | Lists of exactly three, especially three adjectives before a noun or three parallel noun phrases after a colon, appearing whenever the draft enumerates anything. |
| Replace with | Keep the strongest two items and drop the third, or promote one item into its own sentence with the detail that justified including it. Four-item lists and two-item lists are both fine and both underused. |
| Target frequency | Rhetorical triples are ancient and common in good writing, so the target is not zero. The marker is exclusivity: human writers produce twos, fours and sevens at rates comparable to threes, while model prose converges on three. I have no published count for this and would not trust one that ignored genre. |
| Over-correction failure | Deliberate asymmetry that draws attention to itself, or a list of four where the fourth item is filler. Padding a list to avoid a triple is worse than the triple. |
| Confidence | Observed for the convergence, unsupported for any specific rate. Apply with judgement rather than by search and replace. |

| Before | After |
|---|---|
| The programme was ambitious, expensive, and ultimately unworkable. | The programme was ambitious and expensive. It was also unworkable, which the department discovered in year three, after the money was gone. |
| Good soil holds water, feeds microbes, and resists erosion. | Good soil holds water and feeds the microbes that hold it together. |

### S2. The antithetical reframe

| Field | Content |
|---|---|
| Pattern | `It is not just X, it is Y`, `X is not about A; it is about B`, `more than merely X`, `X is not simply Y`. The construction sets up a strawman reading in order to correct it. |
| Replace with | Assert Y directly and give the reason it holds. If X was worth mentioning, make it a concession in its own sentence rather than a springboard. |
| Target frequency | Unsupported by any count I can offer. The construction exists in human rhetoric, mostly in speeches and opinion writing, at something like once per piece rather than once per section. |
| Over-correction failure | Genuine contrast flattened. Where the reader really does hold the wrong model, correcting it explicitly is the right move, and refusing to do so leaves them with the wrong model. |
| Confidence | Observed. |

| Before | After |
|---|---|
| Bicycle infrastructure is not just about bike lanes. It is about who the street belongs to. | Bicycle infrastructure is a claim on the street, and the lane is only the visible part of the argument. The contested part is the parking. |
| Replicated storage is not merely a technical detail; it is the difference between a hobby project and a system you can trust. | Replicated storage is why I keep the family photographs on the cluster instead of on one disk in a machine under the stairs. |

### S3. Participial result clauses

| Field | Content |
|---|---|
| Pattern | A trailing clause that explains the consequence of the main clause: `, allowing users to...`, `, ensuring that...`, `, making it easier to...`, `, highlighting the importance of...`, `, thereby reducing...`. Frequently two of them stacked on one sentence. |
| Replace with | Promote the consequence to its own sentence with a real subject, or delete it where it restates the main clause. When the causal link matters, use a finite verb: `which means`, `so`, `and`. |
| Target frequency | No count available. Participial adjuncts of this kind appear in edited nonfiction, but a rate above roughly one per three hundred words is worth reducing, and stacked pairs are worth eliminating almost entirely. The number is a working heuristic and not a measurement. |
| Over-correction failure | A run of short main clauses connected by `so`, which is its own tic. Vary the repair: some become sentences, some become `which` clauses, some are simply deleted because the reader could see the consequence. |
| Confidence | Observed, and the highest-yield operation in this document despite the lack of a number. |

| Before | After |
|---|---|
| The cluster stores its state in etcd, allowing nodes to rejoin without manual intervention and ensuring that the control plane remains available during a rolling upgrade. | The cluster keeps its state in etcd. A node that drops out rejoins on its own, and the control plane stays up through a rolling upgrade. |
| The bank raised the base rate by half a point, signalling its intent to bring inflation under control and reassuring markets that the previous quarter's caution had ended. | The bank raised the base rate by half a point. Markets read the size of the move rather than the statement, and took it as the end of the previous quarter's caution. |

### S4. Sentence-length variance

| Field | Content |
|---|---|
| Pattern | Sentences clustered within a narrow band, typically fifteen to twenty-five words, with no very short sentences and few long ones. Paragraphs where every sentence has roughly the same shape as its neighbours. |
| Replace with | Join two adjacent sentences that share a subject into one longer one, and split or truncate a third into something under eight words. Aim for at least one short sentence per paragraph of four or more. |
| Target frequency | Counts of expository prose in the Brown corpus put mean sentence length near twenty words. The dispersion is the marker rather than the mean: human nonfiction commonly shows a standard deviation somewhere around half the mean, while model drafts cluster far tighter. A working target is a standard deviation of at least 0.4 times the mean, with one sentence under eight words per three hundred. |
| Over-correction failure | Staccato prose that mistakes fragments for voice. "The kiln was hot. Very hot. Too hot." reads as a different machine, not as a person. Long sentences also need to appear, and a fifty-word sentence that holds together is a stronger human signal than a three-word one. |
| Confidence | Measured for the mean, observed for the dispersion target. |

| Before | After |
|---|---|
| The kiln reaches temperature in about six hours. The clay must be bone dry before firing. Moisture trapped in the body will turn to steam. Steam expands and cracks the pot. Potters call this a blowout. | The kiln reaches temperature in about six hours, but the clay has to be bone dry before it goes anywhere near it, because any moisture left in the body turns to steam, and steam expands. The pot cracks. Potters call it a blowout. |
| Bees navigate using polarised light. They also use landmarks near the hive. Their dances encode distance and direction. Foragers recruit nestmates in this way. The system is remarkably accurate. | Bees navigate by polarised light and by landmarks near the hive. Back inside, a forager dances the bearing and distance of what she found, and her nestmates fly out on that information alone, sometimes several hundred metres, and arrive. It works. |

---

## 5. Inter-sentential patterning

### I1. Sentence-initial connectives

| Field | Content |
|---|---|
| Pattern | Most sentences opening with an explicit logical connective: `Moreover`, `Furthermore`, `Additionally`, `However`, `Consequently`, `Ultimately`, `Notably`, `Importantly`. Often three consecutive sentences each carrying one. |
| Replace with | Delete the connective where the relation is obvious from content, which is most of the time, or move it inside the sentence: `The harbour silted up, and the wool trade shifted east with it`. Keep one or two per page where the logical turn is genuinely hard to see. |
| Target frequency | Biber's register work shows linking adverbials are markedly more frequent in academic prose than in news or fiction, so the target depends on genre. In general nonfiction, a connective opening more than one sentence in five is high. In a philosophy paper it is normal. |
| Over-correction failure | Paragraphs where the reader cannot tell whether the next sentence supports the last one or contradicts it. Contrastive connectives earn their place more often than additive ones; `however` is more often load-bearing than `moreover`. |
| Confidence | Measured for the register split, observed for the model-versus-human difference. |

| Before | After |
|---|---|
| Furthermore, the harbour silted up during the fifteenth century. Moreover, the wool trade shifted east. Consequently, the town's tax receipts fell sharply. | The harbour silted up during the fifteenth century and the wool trade shifted east. Tax receipts fell by two thirds in thirty years, and the town never got them back. |
| Additionally, the compiler inlines small functions. However, this can increase binary size. Therefore, a size budget is advisable. | The compiler inlines small functions, which can bloat the binary. Set a size budget if you are shipping to a device with sixteen megabytes of flash. |

### I2. Restating the previous sentence

| Field | Content |
|---|---|
| Pattern | A sentence that paraphrases the one before it, usually introduced by `In other words`, `Put differently`, `That is to say`, `Essentially`, or by no marker at all. The second sentence adds no information. |
| Replace with | Keep whichever version is clearer and use the recovered space for the next fact, an example, or a number. Where the concept genuinely needs two passes, make the second pass concrete rather than a second abstraction. |
| Target frequency | Restatement is a legitimate teaching device and appears throughout good explanatory writing. I have no count. The test is whether the second sentence contains a word the first did not; if it does not, it is padding. |
| Over-correction failure | Difficult material stated once, tersely, and never illustrated. In pedagogical writing the redundancy is the pedagogy, and cutting it hurts the reader who needed it. |
| Confidence | Observed. |

| Before | After |
|---|---|
| The bridge was closed for eight months. In other words, traffic had to use the ring road for the better part of a year. | The bridge was closed for eight months, and everything went round by the ring road, which added twenty minutes at rush hour. |
| Latency rose sharply after the migration. Put differently, requests took considerably longer to complete once the new cluster was in place. | Latency rose sharply after the migration. The 99th percentile went from eighty milliseconds to just under a second. |

---

## 6. Paragraph and discourse structure

### P1. Uniform paragraph length

| Field | Content |
|---|---|
| Pattern | Every paragraph running three to five sentences, each opening with a topic sentence and closing with a wrap-up, so the page has a visible regular texture. |
| Replace with | Let at least one paragraph in a section run to a single sentence, and let another run long where the material is dense. Paragraph breaks are a rhythmic instrument as much as a logical one, and human writers use them for emphasis. |
| Target frequency | Varies enormously by medium. Web journalism runs one to two sentences per paragraph, academic writing runs six to ten. The marker is uniformity within a single piece rather than any particular length. |
| Over-correction failure | Arbitrary breaks that split an argument mid-step, or a page of one-sentence paragraphs, which is its own recognisable register and belongs to marketing copy. |
| Confidence | Observed. |

| Before | After |
|---|---|
| Three consecutive paragraphs of four sentences each, one on the walls, one on the garrison, one on the relief force. | The paragraph on the garrison runs to eight sentences because the muster rolls survive and the numbers are surprising. The one on the relief force is a single sentence, because it never arrived. |
| A troubleshooting guide in which each of nine failure modes gets a four-sentence paragraph. | The two failure modes that account for most outages get a dozen sentences between them. The other seven are named in a sentence each. |

### P2. The preview frame

| Field | Content |
|---|---|
| Pattern | An opening paragraph announcing what the piece will cover, often with a promise about what the reader will understand by the end: `In this article, we will explore...`, `This guide will walk you through everything you need to know about...`. |
| Replace with | Begin with the most interesting fact, claim, or scene the piece contains. A reader who wants a map has the headings; a reader who wants a reason to continue needs the first sentence to give them one. |
| Target frequency | Explicit previews are standard in academic abstracts and technical documentation, and rare in everything else. Outside those genres, treat any occurrence as a candidate for deletion. |
| Over-correction failure | A piece that plunges into detail with no orientation, so the reader spends three paragraphs working out what the subject is. Long reference documents in particular need their scope stated, and this one states it in a table rather than a paragraph. |
| Confidence | Observed. |

| Before | After |
|---|---|
| In this article, we will explore the history of the Dublin tram network, examine the causes of its decline, and discuss its recent revival. By the end, you will have a clear understanding of how the city's transport priorities have shifted. | Dublin had trams before it had a government of its own. It tore up the tracks in 1949 and spent the next fifty years regretting it. |
| This guide will walk you through everything you need to know about restic snapshots. We will cover initialisation, backup, pruning, and restoration. | Restic's pruning model is the part that catches people out, so it comes first here. Initialisation and backup are two commands each and you can skim them. |

### P3. The terminal summary

| Field | Content |
|---|---|
| Pattern | A closing sentence or paragraph that restates the section immediately above it, frequently opening with `In summary`, `Overall`, `Taken together`, or `In conclusion`. |
| Replace with | End on the last substantive point, or on the consequence that the section has earned but not yet stated. The strongest closing sentence is usually one that adds a fact the reader will remember. |
| Target frequency | Summaries are correct at the end of long documents and in abstracts. At the end of a five-hundred-word section they are almost always redundant. I have no count, and would treat any count as genre-bound. |
| Over-correction failure | A long technical document with no synthesis anywhere, so the reader has to hold twelve sections in their head. The distinction is between restating and synthesising: a summary that says something the sections did not say individually is worth keeping. |
| Confidence | Observed. |

| Before | After |
|---|---|
| The trial ran for eighteen months across four wards. In summary, the trial demonstrated that the intervention was effective, cost-neutral, and acceptable to staff. | The trial ran for eighteen months across four wards. When it ended, three of the four ward managers asked to keep the new rota, which is the finding that moved the board. |
| ...and that is how the cache invalidation works. To summarise this section, we have covered the cache lifecycle, its invalidation triggers, and its failure modes. | ...and that is how the cache invalidation works. The failure mode nobody expects is the one where invalidation succeeds and the write behind it does not. |

### P4. Symmetrical coverage

| Field | Content |
|---|---|
| Pattern | Every subtopic given roughly equal space and equal emphasis, with each claim developed to the same depth, regardless of which one carries the argument. |
| Replace with | Give the load-bearing part of the piece two or three times the space of the others and let minor points go by in a clause. Unevenness is evidence of a writer who has decided what matters. |
| Target frequency | Not statable as a number. The usable check is proportional: if the longest section of a piece is less than twice the shortest, the piece probably has not committed to anything. |
| Over-correction failure | A piece so lopsided that a promised topic gets one sentence, leaving the reader who came for that topic with nothing. Rebalance by cutting the heading, not by padding the section. |
| Confidence | Observed. |

| Before | After |
|---|---|
| A two-thousand-word piece on the siege gives five hundred words each to the walls, the supply lines, the relief force, and the aftermath. | The same piece gives eleven hundred words to the supply lines, because that is where the siege was decided, and disposes of the walls in a paragraph. |
| A comparison of four database engines devotes an identical section to each. | The comparison spends most of its length on the two that are plausible for this workload and explains in two sentences why the other two are not. |

---

## 7. Rhetorical posture

### R1. Balance where the question has an answer

| Field | Content |
|---|---|
| Pattern | Two positions set out at equal length, followed by a sentence declining to choose: `ultimately, the right approach depends on your specific needs`, `there are valid arguments on both sides`, `context is key`. |
| Replace with | State which one you would do and what would change your mind. Where the answer really is conditional, name the condition precisely enough to be checked, so the reader can look at their own case and decide. |
| Target frequency | Not a frequency question. The test is per-instance: for each balanced passage, ask whether the evidence actually balances. Where it does, the balance is honest and should stay. |
| Over-correction failure | Confident assertion on questions that are genuinely open, which is a worse failure than hedging because it is harder for the reader to detect. Contested empirical and political questions should be presented with their real disagreement intact; this operation is about false balance, not about manufacturing opinions. |
| Confidence | Observed. |

| Before | After |
|---|---|
| There are arguments on both sides of the question of whether to run a database inside Kubernetes. Some practitioners favour it for operational consistency, while others prefer managed services. Ultimately, the right choice depends on your specific needs. | Run the database outside the cluster unless someone on your team has restored one from backup and timed it. Operational consistency is a real benefit and it is worth less than a restore path you have actually tested. |
| Whether the Anglo-Saxon Chronicle is reliable for the ninth century has been debated by historians, with compelling arguments on both sides. | The Chronicle is a Wessex document and it flatters Wessex. Use it for chronology, where it is checkable against Frankish annals, and distrust it entirely on motive. |

### R2. Stacked hedges

| Field | Content |
|---|---|
| Pattern | Multiple hedges modifying one claim: `may potentially`, `could arguably suggest`, `it seems likely that perhaps`, `some evidence may indicate`. Often closing with `although further research is needed`. |
| Replace with | Use one hedge, chosen for the actual strength of the evidence, and say what would settle it. `The effect is small and the interval crosses zero` is both more hedged and more useful than three modal verbs. |
| Target frequency | Hedging is dense and appropriate in research writing; Hyland's work on academic discourse documents how central it is to the genre. The marker is stacking rather than presence. One hedge per claim is normal, three is a tic. |
| Over-correction failure | Uncertainty deleted along with the padding, so tentative findings are reported as settled. Strip the redundant hedges and keep the one that reflects the evidence. |
| Confidence | Measured for the academic baseline, observed for the stacking. |

| Before | After |
|---|---|
| It could potentially be argued that the results may possibly suggest a modest effect, although further research is needed. | The effect is small and the confidence interval crosses zero. Treat it as unproven until someone runs it with more than forty participants. |
| Sailors may perhaps have used the astrolabe for latitude, though it seems likely this was somewhat imprecise in practice. | Sailors used the astrolabe for latitude and got within a degree or two on a steady deck. On a rolling one, considerably worse, which is why they preferred to take the reading in harbour. |

### R3. Service-tone reader address

| Field | Content |
|---|---|
| Pattern | Direct address that anticipates the reader's emotional state or credentials: `whether you are a beginner or an expert`, `you will find that`, `do not worry if this seems complex`, `let us dive in`, `you have got this`. |
| Replace with | Address the reader through the material: give the thing that is actually hard about the topic, or the mistake they are most likely to make. Second person is fine and often good; the tic is the reassurance, not the pronoun. |
| Target frequency | Standard and correct in tutorials and consumer documentation. Nearly absent from reportage, criticism and academic writing. Calibrate to genre. |
| Over-correction failure | Instructional writing stripped of all orientation, so a reader who is genuinely new has no idea whether they are meant to understand something yet. Saying "this part is confusing and here is why" is not the same tic. |
| Confidence | Observed. |

| Before | After |
|---|---|
| Whether you are a seasoned developer or just starting out, you will find that understanding memory allocation is a valuable skill on your journey. | Allocation costs show up as latency spikes long before they show up as memory pressure, which is why this matters earlier than most people expect it to. |
| Do not worry if this seems complicated at first. You have got this! | The first two rules cover almost everything. The third exists because of a decision made in 1998 that nobody has been willing to reverse. |

### R4. The uplift coda

| Field | Content |
|---|---|
| Pattern | A closing move to significance, futurity or general wisdom: `as we continue to navigate`, `one thing remains clear`, `the choices we make today`, `it is a journey, not a destination`. The final paragraph zooms out and says nothing checkable. |
| Replace with | End on the most specific thing you have. A closing sentence carrying a number, a name or a physical detail will outperform any generalisation, and it is the sentence the reader will quote. |
| Target frequency | Codas of this kind are conventional in opinion columns and speeches. In reporting, technical writing and criticism they are rare. Where present outside those genres, delete. |
| Over-correction failure | A piece that stops mid-stride because the writer has been told not to conclude. Ending well is not the same as ending with a moral; give the ending an actual last beat. |
| Confidence | Observed. |

| Before | After |
|---|---|
| As we continue to navigate an increasingly complex energy landscape, one thing remains clear: the choices we make today will shape the world of tomorrow. | The grid connection queue is now the binding constraint on new wind capacity, and the queue is an administrative object rather than a physical one. |
| Ultimately, mastering knife skills is a journey rather than a destination, and every cook's path is uniquely their own. | You will know the grip is right when your knuckles stop guiding the blade and start guarding your fingertips. |

---

## 8. Absences

Absence patterns split into two groups, and the split matters more than any individual entry. One group describes things a model can legitimately supply from what it already knows or from the source material in front of it. The other describes things it cannot supply without inventing them.

### 8.1 Remediable absences

Four of the five remediable absences are already operations elsewhere in this document, because the repair for an absence is the same as the repair for the pattern that fills the space. The table below is a locator rather than a new set of rules.

| Absence | Supplied by |
|---|---|
| Uneven attention across a piece | P4 |
| Unequal section and paragraph lengths | P1, P4 |
| Commitment to a position | R1 |
| Removal of the summary that restates the section | P3 |
| Concrete detail in place of abstraction | A1, below |

### A1. Concrete instance in place of abstraction

| Field | Content |
|---|---|
| Pattern | Sentences describing a category of event without naming an instance: `the team faced significant challenges`, `various methods were used`, `several issues arose during deployment`. |
| Replace with | Name one instance and give it a number, a place, a date, or a proper noun, drawn from the source material, the conversation, or established public fact. One specific carries more weight than three abstractions, and the specific usually already exists somewhere in the draft's own inputs. |
| Target frequency | Not statable. The check is per-paragraph: a paragraph of general nonfiction that contains no proper noun, number or physical detail is a candidate, and three such paragraphs in a row is a strong signal. |
| Over-correction failure | Invented specifics. This is the most damaging failure in the entire document, because it converts a stylistic problem into a factual one. A fabricated statistic reads more human and is worse in every way that matters. Where no specific is available, generalise honestly rather than inventing, and shorten the passage instead of decorating it. |
| Confidence | Observed for the pattern, and stated with full confidence for the failure mode. |

| Before | After |
|---|---|
| The team faced significant challenges during the migration but ultimately overcame them through careful planning and collaboration. | The migration failed twice on the same storage volume before anyone thought to check whether the node had been marked under disk pressure. |
| Traditional methods of preserving fish were widely used across coastal communities. | In Achill they split the fish, salted it in barrels for three weeks, and hung it on the roof to dry. |

### 8.2 Non-remediable absences

Model prose lacks personal anecdote, sensory recollection, biographical incident, and the record of a mistake someone actually made. These absences are real and they are among the strongest signals a careful reader picks up on. They cannot be repaired by writing, because writing them means inventing a life.

Do not invent them. An anecdote presented as the writer's own experience is a false claim about who wrote the text and what happened to them, and no gain in register justifies it. This holds even when the anecdote is generic enough to seem harmless, and it holds especially when the surrounding document is otherwise accurate, because accuracy elsewhere is what makes the invention credible.

The correct response is to write in a register that does not call for the material. Reportage, analysis, technical explanation, criticism of a text, and argument from public evidence all run perfectly well without personal experience, and their absence in those genres is unremarkable. Where a first-person register is unavoidable, the honest options are to write from the reader's likely experience rather than the writer's, to attribute experience to a named and real source, or to say plainly that the text is not speaking from experience. If the task itself requires a memoir, the task requires a person, and that is worth saying rather than working around.

---

## 9. Typographic habits

### T1. Em dash density

| Field | Content |
|---|---|
| Pattern | Em dashes carrying most of the parenthetical and appositive work in a text, often two or three in one sentence, and often used where a colon or full stop would be more precise. |
| Replace with | Distribute the work across the available marks. A parenthetical aside takes brackets, an amplification takes a colon, a contrast takes a semicolon, and a genuine interruption keeps the dash. Retaining a few is part of the operation; the aim is to stop the dash being the default. |
| Target frequency | Variation between human authors is larger than the difference between the human and model averages, which is why this marker is over-attributed. A working range for general nonfiction is one per four hundred to one thousand words. Some essayists run several times that and read as unmistakably human. |
| Over-correction failure | Zero em dashes in a long text, which is itself unusual in published prose and reads as suppression. A draft with no dashes anywhere and a lot of parentheses has traded one signature for another. |
| Confidence | Observed. The public salience of this marker exceeds its evidential weight. |

| Before | After |
|---|---|
| The recipe calls for anchovies — three or four — and they dissolve into the sauce entirely — you will not taste them as fish. | The recipe calls for three or four anchovies. They dissolve completely into the sauce, and nobody who eats it will taste fish. |
| Coral bleaching — a stress response rather than death — can reverse — provided the water cools within a few weeks. | Coral bleaching is a stress response, not death. If the water cools within a few weeks the colony can take its algae back, though it will be smaller for years afterwards. |

### T2. Bulleted fragments and bold lead-ins

| Field | Content |
|---|---|
| Pattern | Prose broken into bullets, each opening with a bolded noun phrase and a colon, in a context where the reader expected continuous text. Related habits include a heading every two paragraphs and emoji as section markers. |
| Replace with | Return the material to sentences that connect to each other, keeping lists for things that are genuinely enumerable and unordered. Where a list is right, let the items be full clauses and let the emphasis come from ordering. |
| Target frequency | Governed by medium rather than by any general rate. Reference documentation, runbooks and specifications are correctly list-heavy; essays, reports, emails and articles are not. This document is list-heavy and table-heavy because its reader is a machine addressing specific rules, which is the same exemption. |
| Over-correction failure | Genuinely enumerable material dissolved into a paragraph, so the reader cannot count the steps or find step four. Installation instructions belong in a numbered list and always did. |
| Confidence | Observed. |

| Before | After |
|---|---|
| **Cost:** The scheme is over budget. **Timeline:** Delivery has slipped by two years. **Scope:** Two stations have been cut. | The scheme came in over budget and two years late, and it lost two stations on the way. |
| Key benefits include: improved performance, enhanced security, and better scalability. | It is faster, and the credentials are no longer sitting in the environment. |

---

## 10. The preserve list

These patterns look machine-generated and are not. They appear in good human writing at rates equal to or higher than in model output, and editing them out makes prose worse while making it no more human. Leave them alone.

| Pattern | Why it stays |
|---|---|
| The em dash as such | Widely used by strong human writers. Only the density is a marker, and T1 addresses density rather than presence. |
| The semicolon | Rarer in model output than in careful human prose. A semicolon is evidence of a writer, not of a machine. |
| Parallelism and the rhetorical triple in oratory, argument and criticism | Older than printing and central to how English persuades. S1 targets automatic threes, not the device. |
| `However`, `moreover` and explicit signposting in academic writing | Measured as frequent in that register. Removing them makes an academic text harder to follow. |
| Correct spelling, agreement and consistent tense | Introducing errors as camouflage is the worst available strategy. It degrades the text and does not fool careful readers. |
| Repeating a key term instead of varying it | Technical writing requires the same referent to keep the same name. Elegant variation is a bug there. |
| The Oxford comma, and consistent punctuation generally | A house-style choice with no bearing on authorship. |
| Hedging in scientific and medical writing | Epistemically correct in that genre. R2 targets stacked hedges, not hedging. |
| Headings, tables and numbered lists in reference material | Correct for the medium. See T2 and the register conditions below. |
| Long sentences with multiple subordinate clauses | Under-produced by models rather than over-produced. Encourage these. |
| The word `delve` in British and Irish academic usage | It predates 2023 and it is a normal word. The marker was density in a corpus, not the lexeme in a sentence. |

---

## 11. Register conditions

The operations above assume a default of edited general nonfiction written for human readers. Outside that default, specific operations are suspended. These are rules, and where they apply they override the taxonomy.

| Condition | Operations suspended |
|---|---|
| Technical documentation, runbooks, API references, specifications | T2 entirely, plus P1, P4 and S1. Bullets, uniform structure, parallel phrasing and repeated key terms are correct here. |
| Routine correspondence: acknowledgements, scheduling, confirmations, cover letters | C1 for openings and sign-offs, R3 for courtesy formulas. Formulaic greeting and closing language is the convention and departing from it reads as odd rather than as human. |
| Academic and scientific prose | I1 and R2. Linking adverbials and hedges are load-bearing in this register, and Hyland's account of academic hedging describes a norm rather than a tic. |
| Legal, regulatory and contractual text | Everything. Precision, repetition and fixed formulae take priority over register, and varying sentence length for rhythm in a contract is malpractice. |
| Abstracts, executive summaries and structured reports | P2 and P3. Previewing and summarising is the entire function of the form. |
| Text whose reader is a machine: prompts, configuration, structured data, this document | The whole guide. Optimise for retrieval and unambiguous addressing. |
| First-person narrative, memoir, personal essay | Section 8.2 governs. If the register requires lived experience the model does not have, say so rather than supplying it. |

Two rules in this document cannot be stated without violating themselves, and it is better to name that than to pretend otherwise. The instruction to phrase operations positively is itself a prohibition. The instruction to avoid bolded fragment lead-ins and clipped noun phrases sits inside a document built from tables whose left column is nothing but clipped noun phrases. Both are instances of the last row above: the reader here is a machine looking things up, and the exemption is real rather than convenient.

---

## 12. Revision procedure

Run the passes in this order. The order matters because structural changes delete text that would otherwise be edited at sentence level, and editing sentences you are about to cut is wasted work.

| Pass | What to do |
|---|---|
| 1. Read | Read the draft once without editing. Mark the two or three places where it says something specific. Everything else exists to get the reader to those places. |
| 2. Structure | Cut the preview paragraph (P2) and every section-final summary (P3). Rebalance section lengths toward the marked passages (P4). Vary paragraph lengths (P1). |
| 3. Posture | Take a position where the draft declined to (R1). Reduce stacked hedges to one honest hedge each (R2). Cut the closing coda (R4) and the reassurance (R3). |
| 4. Sentences | Break participial tails (S3). Recast antithetical reframes (S2). Convert automatic triples (S1). Delete or relocate sentence-initial connectives (I1). Cut restatements (I2). |
| 5. Words | Replace inflated verbs (L1), unsupported evaluative adjectives (L2), nominalisations (L3), abstraction nouns (L4), stock metadiscourse (C1) and stock metaphor (C2). |
| 6. Specifics | For each paragraph with no number, name or physical detail, supply one from the source material or the established record (A1). Where none exists, shorten the paragraph. Supply nothing you cannot support. |
| 7. Typography | Redistribute em dashes (T1). Return bulleted fragments to prose where the medium is prose (T2). |
| 8. Measure | Check sentence-length dispersion (S4) and fix it by joining and splitting. Confirm that at least one paragraph opens on something other than its topic sentence. |
| 9. Check | Reread against the preserve list and the register conditions. Restore anything removed that belonged to the genre. |

Stop when any of the following is true. The next change you would make exists only to differ from the previous draft rather than to improve the sentence. Marker frequencies are inside the target ranges rather than at zero, since zero is itself a signal. You have changed more than roughly one sentence in three, at which point you are rewriting rather than revising and should ask whether the draft was the problem. Or you have reached a passage where accuracy is at stake, in which case leave it: quotations, defined terms, numbers, names, and anything a reader might act on stay exactly as they are, whatever they do to the register.

---

## Appendix A: Non-actionable signals

These are real detection surfaces and none of them can be reached by a model editing its own output. They are listed so that no effort is spent attempting them.

| Signal | Why it is out of reach |
|---|---|
| Perplexity under a reference model | A property of the token sequence as scored by another model, set largely at decoding time by temperature, top-p and the sampler. Editing raises it incidentally, but a model cannot observe or target its own perplexity during revision. |
| Token-rank and curvature methods, including DetectGPT-style probability-curvature tests | These compare the text against local perturbations under a scoring model. Nothing in the revision pass changes the geometry deliberately, and attempting to would require access to the scorer. |
| Statistical watermarking, including green-list schemes of the Kirchenbauer type | Embedded during sampling by biasing the token distribution. Heavy paraphrase degrades the signal, but the model doing the paraphrasing cannot verify whether it succeeded, so this is not a target that can be worked toward. |
| Stylometric classifiers trained end to end | They key on distributions across a whole document rather than on any nameable feature, which means there is no per-sentence operation that corresponds to them. |
| Provenance metadata: C2PA manifests, API logs, response headers | Outside the text entirely. |

The practical consequence is that everything in sections 1 to 12 addresses how the text reads to a person. Where the goal is to defeat a statistical detector rather than to write better, this document is the wrong tool and mostly will not work.

---

## Appendix B: Low-confidence patterns

These are worth a glance during pass 5 and are not worth a rule. Each is either too weakly attested or too genre-dependent to be applied mechanically.

| Pattern | Note |
|---|---|
| Unicode punctuation in plain-text contexts | Curly quotes, true ellipsis characters and non-breaking spaces in an email thread where every other message uses straight quotes and three full stops. Match the medium. Attested informally, no counts. |
| Title Case On Every Heading | Common in model output, mixed in human writing, entirely a house-style question. |
| `Let us take a closer look at` and similar transition sentences | Covered in substance by C1, listed separately because it survives that operation surprisingly often. |
| Rhetorical questions used as section openers | Frequent in model prose and in a lot of human magazine writing too. Weak signal. |
| Numbered lists that always contain five or seven items | Anecdotal only. The round-number pull is real but I have no measurement of it. |
| Alliteration in headings and opening sentences | Reported as a model habit. I cannot separate it from ordinary editorial practice. |
| Symmetrical opening and closing sentences in a paragraph | Related to P1 and possibly the same phenomenon at smaller scale. |

---

## Known Gaps

Most of the target frequencies in this document are not measurements. Only three entries rest on published counts, and two of those come from scientific abstracts rather than from the general nonfiction this guide is aimed at. The ranges elsewhere are working heuristics stated in the format the schema required, and the honest reading of a range marked "observed" is that it encodes a direction and an order of magnitude, nothing finer.

There is no single distribution called competent human writing. The implied target here is edited general nonfiction of the sort that appears in magazines, long-form journalism and good technical blogging. A model applying this guide to fiction, to poetry, to legal drafting or to conversational messaging will produce something worse than it started with, and the register conditions in section 11 are a partial defence rather than a complete one.

Three of the operations resisted specification. S1 has no rule that distinguishes a rhetorical triple from an automatic one except judgement about whether the third item earns its place, and I could not reduce that to something checkable. P1 depends on a sense of rhythm that I can illustrate but not define. R1 requires knowing whether the evidence on a question actually balances, which is a question about the world rather than about the prose, and no style guide can answer it.

The failure mode most likely to be caused by this document is fabrication under A1. The instruction to supply concrete detail and the inability to supply it honestly meet in every abstract paragraph, and the pressure runs one way. If any single rule here should be applied conservatively, it is that one.

Two smaller risks are worth naming. Over-correction produces a text that is recognisable as edited-to-avoid-detection, which is a worse outcome than the original register and harder to fix. And detector evasion and good prose are different objectives that overlap only partly, so a draft optimised hard against the list above can end up less clear than the draft it replaced, at which point the exercise has failed on its own terms.

Finally, this guide has a shelf life. The markers it describes come from a particular generation of models trained on a particular mix of data, and both change. Documents like this one become training data, which flattens the very differences they describe. Anything here that turns out to be wrong will be wrong in the direction of describing a register that no longer exists.
