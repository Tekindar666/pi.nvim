if vim.g.loaded_pi then
  return
end
vim.g.loaded_pi = true

vim.api.nvim_create_user_command("PiConnect", function()
  require("pi.commands").connect()
end, { desc = "Choose a local Pi instance" })

vim.api.nvim_create_user_command("PiDisconnect", function()
  require("pi.commands").disconnect()
end, { desc = "Disconnect from Pi or cancel selection" })

vim.api.nvim_create_user_command("PiPrompt", function(options)
  require("pi.prompt").open(options)
end, { range = true, desc = "Compose a question with source file or line-range context" })

vim.api.nvim_create_user_command("PiDraft", function()
  require("pi.prompt").append()
end, { desc = "Append the retained question to Pi's draft without submitting" })

vim.api.nvim_create_user_command("PiSubmit", function()
  require("pi.commands").submit()
end, { desc = "Explicitly submit Pi's current draft" })
