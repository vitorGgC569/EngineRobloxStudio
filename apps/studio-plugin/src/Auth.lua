--!strict
-- Replaced only in the locally installed plugin build.  The repository copy
-- intentionally contains no credential and therefore cannot authenticate to a
-- production hub by itself.

return table.freeze({
	bearerToken = "",
	installationId = "",
})
