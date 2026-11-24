-- Starting data. Safe to read; run once after 001.

insert into locations (code, name) values
  ('CBP', 'Central Ban Pamekasan');

-- Categories = the same list as the queue job tags, so the two systems agree.
insert into categories (code, name, sort) values
  ('BAN', 'Ban', 1),
  ('BAL', 'Balancing', 2),
  ('SPO', 'Spooring', 3),
  ('OLI', 'Oli / Service ringan', 4),
  ('KAK', 'Kaki-kaki', 5),
  ('REM', 'Rem', 6),
  ('AKI', 'Aki / Kelistrikan', 7),
  ('LAI', 'Lainnya', 8);

insert into price_lists (name, is_default) values ('Umum', true);

-- Walk-in customer who won't give details
insert into customers (name) values ('UMUM');

insert into car_models (brand, model) values
  ('Toyota','Avanza'),('Toyota','Innova'),('Toyota','Innova Zenix'),('Toyota','Rush'),
  ('Toyota','Calya'),('Toyota','Agya'),('Toyota','Fortuner'),('Toyota','Hilux'),
  ('Toyota','Veloz'),('Toyota','Yaris'),('Daihatsu','Xenia'),('Daihatsu','Terios'),
  ('Daihatsu','Sigra'),('Daihatsu','Ayla'),('Daihatsu','Gran Max'),('Daihatsu','Luxio'),
  ('Honda','Brio'),('Honda','Jazz'),('Honda','Mobilio'),('Honda','BR-V'),('Honda','HR-V'),
  ('Honda','CR-V'),('Suzuki','Ertiga'),('Suzuki','XL7'),('Suzuki','Carry'),('Suzuki','APV'),
  ('Mitsubishi','Xpander'),('Mitsubishi','Pajero Sport'),('Mitsubishi','L300'),
  ('Mitsubishi','Colt Diesel'),('Isuzu','Panther'),('Isuzu','Elf'),('Isuzu','D-Max'),
  ('Nissan','Grand Livina'),('Wuling','Confero'),('Hyundai','Creta'),('Hyundai','Stargazer');
