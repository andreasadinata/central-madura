-- Makes Andreas (the existing login andreasadinata@hotmail.com) the owner, based at CBP.
insert into profiles (id, full_name, email, role, location_id)
values ('4bb7b2bf-09ac-441a-b0de-3f44c2abdde1', 'Andreas', 'andreasadinata@hotmail.com', 'owner',
        (select id from locations where code = 'CBP'));
