# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Ash requires every project to make an explicit choice about how string
# length is counted (ash ~> 3.5 installer default). This library's own
# fact-record test resource (test/support/fact_records.ex) carries a
# :string attribute, so the choice is made here; hosts set their own.
import Config

config :ash, default_string_length_count: :codepoints

# The set evaluator's resource-path tests seed an ETS-backed Ash resource;
# ash logs every create at :debug, which is noise in test output.
if config_env() == :test do
  config :logger, level: :warning
end
