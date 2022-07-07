class CreatePat < ActiveRecord::Migration[6.1]
  def change
    create_table :pats, id: false do |t|
      t.string :guild_id, primary_key: true
      t.string :pat
    end
  end
end
