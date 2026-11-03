--!strict
-- Minimal typed signal for client controllers (single payload value).

export type Signal<T> = {
	Connect: (self: Signal<T>, handler: (T) -> ()) -> () -> (),
	Fire: (self: Signal<T>, value: T) -> (),
}

local Signal = {}

function Signal.new<T>(): Signal<T>
	local handlers: { (T) -> () } = {}

	local signal: Signal<T> = {
		Connect = function(_self: Signal<T>, handler: (T) -> ()): () -> ()
			table.insert(handlers, handler)
			return function()
				local index = table.find(handlers, handler)
				if index then
					table.remove(handlers, index)
				end
			end
		end,
		Fire = function(_self: Signal<T>, value: T)
			-- Snapshot handlers so (dis)connecting during dispatch is safe.
			for _, handler in table.clone(handlers) do
				task.spawn(handler, value)
			end
		end,
	}
	return signal
end

return Signal
