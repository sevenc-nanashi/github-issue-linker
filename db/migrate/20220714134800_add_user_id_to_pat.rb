class AddUserIdToPat < ActiveRecord::Migration[6.1]
  def change
    add_column :pats, :user_id, :string
  end
end
