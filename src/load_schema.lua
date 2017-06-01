local yang = require("lib.yang.yang")
local data = require("lib.yang.data")

function run (args)
   print("load_schema")
   local schema = yang.load_schema_by_name("ietf-alarms")
   local grammar = data.data_grammar_from_schema(schema)
   local parse = data.data_parser_from_grammar(grammar)
   print("ok")
end

run(main.parameters)
