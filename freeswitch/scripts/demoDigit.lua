fs_logger("notice","Inside the demoooooo digitttt kuaaaaaaaa");

xml = {};
        table.insert(xml, [[<?xml version="1.0" encoding="UTF-8" standalone="no"?>]]);
        table.insert(xml, [[<document type="freeswitch/xml">]]);
        table.insert(xml, [[<section name="dialplan" description="Play get digit Dialplan">]]);
        table.insert(xml, [[<context name="]]..params:getHeader("Caller-Context")..[[">]]);
	table.insert(xml, [[<extension name="]]..destination_number..[[">]]);
	table.insert(xml, [[<condition field="destination_number" expression="]]..skip_special_char(originate_destination_number)..[[">]]);
        table.insert(xml, [[<action application="answer"/>]]);
        --table.insert(xml, [[<action application="sleep" data="500"/>]]);
        table.insert(xml, [[<action application="lua" data="playAndGetDigits.lua"/>]]);
        table.insert(xml, [[<action application="hangup"/>]]);
        table.insert(xml, [[</condition>]]);
        table.insert(xml, [[</extension>]]);
        table.insert(xml, [[</context>]]);
        table.insert(xml, [[</section>]]);
        table.insert(xml, [[</document>]]);
        XML_STRING = table.concat(xml, "\n");
        fs_logger("info","Generated XML:\n" .. XML_STRING)
