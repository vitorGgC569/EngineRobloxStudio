# Original asset creation boundary

`rqe.assets.creation` is the generic contract layer for creating meshes,
audio, animations and icons.  It complements discovery and publication; it
does not replace either one.

The input is a versioned creative brief containing the exact provider,
tool/version, model/version, prompt, seed, reference hashes and provenance,
rights evidence, expected media type and validation profile.  The canonical
brief hash is also the job ID, so retrying the same brief cannot silently
become a different generation request.

The output is an immutable receipt.  Completed bytes and previews are copied
to a content-addressed object store, measured locally, and bound into the
receipt.  RQE rejects missing files, altered bytes, an explicit placeholder,
unverified commercial rights, unavailable tools/models and outputs that fail
the existing type-specific `LocalAssetValidator`.

`WorkerOutboxCreationProvider` is the boundary for a professional external
creation service.  It only writes a typed JSON request and reads a typed JSON
result from fixed directories.  It accepts no command or executable field and
never starts a process.  Credentials are represented by an opaque reference,
not copied into job artifacts.  Missing credentials or an unavailable tool is
`BLOCKED`; a queued request is `PROGRESSED/QUEUED` with no invented output.

## Validation status

The contract, ledger, fake provider and outbox behavior are
`STATICALLY_VALIDATED` by automated tests.  The fake provider returns test
fixtures and is never evidence that generation works.

Real mesh/audio/animation/icon creation remains `NOT_VALIDATED` until a real
provider or vertical worker is configured and exercised.  Even a successful
creation receipt has `productionReady=false`: it proves only that exact local
bytes are ready to enter publication.  Roblox upload, moderation approval,
declarative integration and runtime/visual verification remain mandatory
downstream stages.

