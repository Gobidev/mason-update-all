local registry = require('mason-registry')

local M = {}

---@class MasonUpdateAllSettings
local default_settings = {
    -- Whether a notification should be shown when there are no updates.
    ---@type boolean?
    show_no_updates_notification = true,
    -- Whether a notification should be shown when we're checking for updates.
    ---@type boolean?
    show_checking_for_updates_notification = true,
}

M.current = vim.deepcopy(default_settings)

-- Cache headless mode at startup to avoid unsafe calls inside event loop
local IS_HEADLESS = #vim.api.nvim_list_uis() == 0

---@param err unknown
---@return string
local function error_to_string(err)
    if type(err) == 'table' then
        local parts = {}
        for _, value in ipairs(err) do
            parts[#parts + 1] = tostring(value)
        end
        if #parts > 0 then
            return table.concat(parts, '; ')
        end
        return vim.inspect(err)
    end
    return tostring(err)
end

-- Smart message printer:
-- - uses io.stdout (io.stderr for warnings and errors) in headless mode for clean CLI output
-- - uses vim.notify in interactive mode if available
-- - falls back to print() otherwise
---@param message string
---@param level integer?
local function print_message(message, level)
    level = level or vim.log.levels.INFO
    if IS_HEADLESS then
        local stream = level >= vim.log.levels.WARN and io.stderr or io.stdout
        stream:write('[mason-update-all] ' .. message .. '\n')
    elseif vim.notify then
        vim.notify(message, level, { title = 'Mason Update All' })
    else
        print('[mason-update-all] ' .. message)
    end
end

local function trigger_complete()
    -- Trigger autocmd
    vim.schedule(function()
        vim.api.nvim_exec_autocmds('User', {
            pattern = 'MasonUpdateAllComplete',
        })
    end)
end

function M.update_all()
    local any_update = false -- Whether any package was updated
    local any_error = false -- Whether any package failed to update
    local running_count = 0 -- Currently running jobs
    local finished = false -- Whether completion has already been reported

    local function check_done()
        if finished or running_count > 0 then
            return
        end
        finished = true

        if any_error then
            print_message('Finished updating packages with errors', vim.log.levels.WARN)
        elseif any_update then
            print_message('Finished updating all packages')
        elseif M.current.show_no_updates_notification then
            print_message('Nothing to update')
        end

        trigger_complete()
    end

    if M.current.show_checking_for_updates_notification then
        print_message('Fetching updates')
    end

    -- Update the registry
    registry.update(function(success, err)
        if not success then
            any_error = true
            print_message('Error fetching updates: ' .. error_to_string(err), vim.log.levels.ERROR)
            check_done()
            return
        end

        local ok, packages = pcall(registry.get_installed_packages)
        if not ok then
            any_error = true
            print_message('Error listing installed packages: ' .. error_to_string(packages), vim.log.levels.ERROR)
            check_done()
            return
        end

        -- Iterate installed packages
        for _, pkg in ipairs(packages) do
            running_count = running_count + 1

            local launched, launch_err = pcall(function()
                -- Fetch for new version
                local latest_version = pkg:get_latest_version()
                local current_version = pkg:get_installed_version()
                if current_version ~= latest_version then
                    any_update = true
                    print_message(('Updating %s from %s to %s'):format(pkg.name, current_version, latest_version))
                    pkg:install({}, vim.schedule_wrap(function(install_success, result)
                        running_count = running_count - 1
                        if install_success then
                            print_message(('Updated %s to %s'):format(pkg.name, latest_version))
                        else
                            any_error = true
                            print_message(
                                ('Failed to update %s: %s'):format(pkg.name, error_to_string(result)),
                                vim.log.levels.ERROR
                            )
                        end

                        -- Done
                        check_done()
                    end))
                else
                    running_count = running_count - 1
                end
            end)

            if not launched then
                running_count = running_count - 1
                any_error = true
                print_message(
                    ('Failed to update %s: %s'):format(pkg.name, error_to_string(launch_err)),
                    vim.log.levels.ERROR
                )
            end
        end

        -- Done
        check_done()
    end)
end

---@param opts MasonUpdateAllSettings?
function M.setup(opts)
    opts = opts or {}
    M.current = vim.tbl_deep_extend('force', M.current, opts)
    vim.api.nvim_create_user_command('MasonUpdateAll', M.update_all, {
        desc = 'Update all installed Mason packages',
        force = true,
    })
end

return M
