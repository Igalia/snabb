module(..., package.seeall)

local yang = require("lib.yang.yang")
local data = require('lib.yang.data')

local leafref_schema = [[module test-schema {
   namespace "urn:ietf:params:xml:ns:yang:test-schema";
   prefix "test";

   container test {
      list interface {
         leaf name {
            type string;
         }
      }

      leaf mgmt {
         type leafref {
            path "../interface/name";
         }
      }
   }
}]]

function selftest (args)
   local leafref_conf = [[
      test {
         interface {
            name "eth0";
         }
         mgmt "eth0";
      }
   ]]

   local loaded_schema = yang.load_schema(leafref_schema)
   assert(loaded_schema.body.test.body.mgmt.type.kind == "leaf")

   local grammar = data.data_grammar_from_schema(loaded_schema)
   local parse = data.data_parser_from_grammar(grammar)
   local model = parse(leafref_conf)
   assert(model)

   print("selftest: ok")
end
