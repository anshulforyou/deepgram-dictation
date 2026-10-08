std = "lua54"
max_line_length = 120
read_globals = { "hs" }

files["spec/"] = { std = "+busted" }
exclude_files = { ".luarocks/**", ".lua/**" }
