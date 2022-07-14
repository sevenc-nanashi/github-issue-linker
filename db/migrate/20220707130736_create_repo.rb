class CreateRepo < ActiveRecord::Migration[6.1]
  def change
    create_table :repos do |t|
      t.string :repo

      t.string :prefix, default: "#"
      t.string :channel_id, null: true
      t.string :guild_id
    end
  end
end
