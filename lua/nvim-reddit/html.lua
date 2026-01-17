local M = {}

local ENTITY_MAP = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = "\"",
    nbsp = " "
}

---@param text string
---@return string
function M.decode(text)
    text = text:gsub("&(%a+);", ENTITY_MAP)

    text = text:gsub("&#(%d+);", function(n)
        return vim.fn.nr2char(tonumber(n, 10))
    end)

    text = text:gsub("&#x([%da-fA-F]+);", function (n)
        return vim.fn.nr2char(tonumber(n, 16))
    end)

    return text
end

---@param element TSNode
---@param source string
---@return fun(): string|TSNode|nil
function M.iter_element_child_nodes(element, source)
    local i = 1
    local count = element:child_count()
    local _, _, offset = element:child(0):end_()
    -- print(vim.treesitter.get_node_text(element, source))

    return function()
        if i == count - 1 then
            return nil
        end
        local next_elm
        while true do
            next_elm = element:child(i) ---@cast next_elm -?
            local t = next_elm:type()
            if t == "text" or t == "entity" then
                i = i + 1
            else
                break
            end
        end

        local _, _, next_start = next_elm:start()
        local _, _, next_end = next_elm:end_()

        if next_start > offset  then
            local text = source:sub(offset + 1, next_start)
            offset = next_end
            return text
        else
            offset = next_end
            i = i + 1
            return next_elm
        end
    end
end

---@param element TSNode
---@param source string
---@return string, table<string, string>
function M.get_element_info(element, source)
    local start_tag = element:child(0) --- @cast start_tag -?
    local tag_name = start_tag:named_child(0) --- @cast tag_name -?
    local tag_name_text = vim.treesitter.get_node_text(tag_name, source)
    local attrs = {}
    for i = 1, start_tag:named_child_count() - 1 do
        local attribute = start_tag:named_child(i) ---@cast attribute -?
        local attribute_name = attribute:named_child(0) ---@cast attribute_name -?
        local quoted_attribute_value = attribute:named_child(1) ---@cast quoted_attribute_value -?
        local attribute_value = quoted_attribute_value:named_child(0) ---@cast attribute_value -?
        attrs[vim.treesitter.get_node_text(attribute_name, source)] = M.decode(vim.treesitter.get_node_text(attribute_value, source))
    end
    return tag_name_text, attrs
end

---@class NvimReddit.RichTextCommand
---@field opening boolean
---@field type string
---@field extra string?

---@alias NvimReddit.RichText (string|NvimReddit.RichTextCommand)[]

---@param element TSNode
---@param source string
---@return NvimReddit.RichText
function M.parse_inner(element, source)
    --- @type NvimReddit.RichText
    local stream = {}
    for node in M.iter_element_child_nodes(element, source) do
        if type(node) == "string" then
            local sanitized = M.decode(node):gsub("\n", " ")
            table.insert(stream, sanitized)
        else
            local element_name, attrs = M.get_element_info(node, source)
            if element_name == "br" then
                table.insert(stream, {
                    opening = true,
                    type = "br"
                })
                goto continue
            end
            -- ol and ul will not be in normal paragraphs, and we want to ignore them when we
            -- use this function to parse list elements with a single paragraph (implicit,
            -- no p element surrounding it) but with an ending sublist element
            if element_name == "ol" or element_name == "ul" then
                goto continue
            end

            if element_name == "img" then
                table.insert(stream, "<gif>")
                goto continue
            end

            ---@type string?
            local extra = nil
            if element_name == "a" then
                extra = attrs.href
            end

            table.insert(stream, {
                opening = true,
                type = element_name,
                extra = extra
            })
            local inner = M.parse_inner(node, source)
            for _, seg in ipairs(inner) do
                table.insert(stream, seg)
            end
            table.insert(stream, {
                opening = false,
                type = element_name
            })
        end
        ::continue::
    end
    return stream
end

---@class List
---@field ordered boolean
---@field items ListItem[]

---@class ListItem
---@field content NvimReddit.RichText[]
---@field sublist List?

---@param element TSNode
---@param source string
---@return List
function M.parse_list(element, source)
    local name = M.get_element_info(element, source)
    local ordered = name == "ol"
    local items = {}
    for i = 1, element:named_child_count() - 2 do
        local li = element:named_child(i) ---@cast li -?
        local child_count = li:named_child_count()
        if child_count == 2 then
            table.insert(items, {
                content = {}
            })
            goto continue
        end

        local sublist = nil
        local last_child = li:named_child(child_count - 2) ---@cast last_child -?
        if last_child:type() == "element" then
            local last_child_name = M.get_element_info(last_child, source)
            if last_child_name == "ol" or last_child_name == "ul" then
                sublist = M.parse_list(last_child, source)
                child_count = child_count - 1
                if child_count == 2 then
                    table.insert(items, {
                        content = {},
                        sublist = sublist
                    })
                    goto continue
                end
            end
        end

        local content = {}

        local first_child = li:named_child(1) ---@cast first_child -?
        if li:named_child(1):type() == "element" then
            local first_child_name = M.get_element_info(first_child, source)
            if first_child_name == "p" then
                for j = 1, child_count - 2 do
                    local p = li:named_child(j) ---@cast p -?
                    local richtext = M.parse_inner(p, source)
                    table.insert(content, richtext)
                end
                goto insert
            end
        end

        content[1] = M.parse_inner(li, source)

        ::insert::
        table.insert(items, {
            content = content,
            sublist = sublist
        })

        ::continue::
    end

    return {
        ordered = ordered,
        items = items
    }
end

---@class NvimReddit.Block
---@field type string
---@field content any

-- This function is very unsafe. it does almost no checks on the tree,
-- assuming that reddit has formed it well. i'll make it safe if there
-- are every any problems :)

---Parse an html string into a series of markdown "blocks"
---@param html string
---@return NvimReddit.Block[]
function M.parse(html)
    local parser = vim.treesitter.get_string_parser(html, "html")
    local tree = parser:parse(true)[1]
    local root = tree:root()
    local container
    for i = 0, root:named_child_count() do
        container = root:child(i) ---@cast container -?
        if container:type() == "element" then
            break
        end
    end

    ---@type NvimReddit.Block[]
    local blocks = {}

    for i = 1, container:child_count() - 2 do
        local element = container:child(i) ---@cast element -?
        local name = M.get_element_info(element, html)

        if name == "p" then
            local richtext = M.parse_inner(element, html)
            table.insert(blocks, {
                type = "richtext",
                content = richtext
            })
        elseif name == "h1" or name == "h2" or name == "h3" or name == "h4" or name == "h5" or name == "h6" then
            local richtext = M.parse_inner(element, html)
            table.insert(richtext, 1, {
                opening = true,
                type = name
            })
            table.insert(richtext, {
                opening = false,
                type = name
            })

            table.insert(blocks, {
                type = "richtext",
                content = richtext
            })
        elseif name == "ol" or name == "ul" then
            local list = M.parse_list(element, html)
            table.insert(blocks, {
                type = "list",
                content = list
            })
        elseif name == "blockquote" then
            -- assuming that blockquote elements always have a single child paragraph
            local paragraph = element:child(1) ---@cast paragraph -?
            local richtext = M.parse_inner(paragraph, html)
            table.insert(richtext, 1, {
                opening = true,
                type = "blockquote"
            })
            table.insert(richtext, {
                opening = false,
                type = "blockquote"
            })

            table.insert(blocks, {
                type = "blockquote",
                content = richtext
            })
        elseif name == "hr" then
            table.insert(blocks, {
                type = "hr"
            })
        else
            print("we don't support this element:", name)
        end
    end

    return blocks
end

return M
