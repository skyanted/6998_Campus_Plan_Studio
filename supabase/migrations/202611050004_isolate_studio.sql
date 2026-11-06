begin;
-- Studio starts with independent copies; formal IDs and history remain untouched.
create table private.lab_chains (like private.week7_chains including all);
insert into private.lab_chains overriding system value select * from private.week7_chains;
alter table private.lab_chains enable row level security;
revoke all on private.lab_chains from public,anon,authenticated;
create table private.lab_steps (like private.week7_steps including all);
insert into private.lab_steps overriding system value select * from private.week7_steps;
alter table private.lab_steps enable row level security;
revoke all on private.lab_steps from public,anon,authenticated;
create table private.lab_mix (like private.week7_mix including all);
insert into private.lab_mix overriding system value select * from private.week7_mix;
alter table private.lab_mix enable row level security;
revoke all on private.lab_mix from public,anon,authenticated;
create table private.lab_terms (like private.week7_terms including all);
insert into private.lab_terms overriding system value select * from private.week7_terms;
alter table private.lab_terms enable row level security;
revoke all on private.lab_terms from public,anon,authenticated;
create table private.lab_examples (like private.week7_examples including all);
insert into private.lab_examples overriding system value select * from private.week7_examples;
alter table private.lab_examples enable row level security;
revoke all on private.lab_examples from public,anon,authenticated;
create table private.lab_app_rules (like private.week7_app_rules including all);
insert into private.lab_app_rules overriding system value select * from private.week7_app_rules;
alter table private.lab_app_rules enable row level security;
revoke all on private.lab_app_rules from public,anon,authenticated;
create table private.lab_generation_settings (like private.week7_generation_settings including all);
insert into private.lab_generation_settings select * from private.week7_generation_settings;
alter table private.lab_generation_settings enable row level security;
revoke all on private.lab_generation_settings from public,anon,authenticated;
create table private.lab_runs (like private.studio_runs including all);
insert into private.lab_runs select * from private.studio_runs;
alter table private.lab_runs enable row level security;
revoke all on private.lab_runs from public,anon,authenticated;
-- Copies are experiments, never candidates for public generation traffic.
update private.lab_mix set weight=0;
alter table private.lab_steps add foreign key(chain_id) references private.lab_chains(id) on delete cascade;
alter table private.lab_mix add foreign key(chain_id) references private.lab_chains(id) on delete cascade;
alter table private.lab_runs add foreign key(shared_chain_id) references private.lab_chains(id) on delete set null;
do $$declare t text;s text;v bigint;begin
 foreach t in array array['chains','steps','mix','terms','examples'] loop
 s:=pg_get_serial_sequence('private.lab_'||t,'id');
 execute format('select coalesce(max(id),0)+1 from private.lab_%I',t) into v;
 if s is not null then perform setval(s,v,false);end if;
 end loop;
end$$;
-- Clone the guarded operations with all mutable content mapped to the lab.
do $$declare src text;dst text;d text;t text;sig text;begin
 for src,dst in select * from (values
 ('private.week7_admin_app_rules()','private.lab_admin_app_rules'),
 ('private.week7_admin_set_app_rules(text,text)','private.lab_admin_set_app_rules'),
 ('private.week7_admin_save(text,text,bigint,jsonb,text)','private.lab_admin_save'),
 ('private.studio_context()','private.lab_context'),
 ('private.studio_rule_blocks()','private.lab_rule_blocks'),
 ('private.studio_library()','private.lab_library'),
 ('private.studio_validate_selection(jsonb)','private.lab_validate_selection'),
 ('private.studio_step_context(private.week7_steps)','private.lab_step_context'),
 ('private.studio_revision(bigint)','private.lab_revision'),
 ('private.studio_snapshot(bigint)','private.lab_snapshot'),
 ('private.studio_library_save(jsonb)','private.lab_library_save'),
 ('public.studio_command(text,jsonb)','public.studio_lab_command')) x loop
 d:=pg_get_functiondef(src::regprocedure);
 d:=replace(d,split_part(src,'(',1),dst);
 foreach t in array array['chains','steps','mix','terms','examples','app_rules'] loop d:=replace(d,'private.week7_'||t,'private.lab_'||t);end loop;
 d:=replace(d,'private.week7_generation_settings','private.lab_generation_settings');

 d:=replace(d,'private.studio_runs','private.lab_runs');
 foreach t in array array['context','rule_blocks','library','validate_selection','step_context','revision','snapshot','library_save'] loop d:=replace(d,'private.studio_'||t,'private.lab_'||t);end loop;
 d:=replace(d,'private.week7_admin_set_app_rules','private.lab_admin_set_app_rules');
 d:=replace(d,'private.week7_admin_app_rules','private.lab_admin_app_rules');
 d:=replace(d,'private.week7_admin_save','private.lab_admin_save');
 if dst='private.lab_admin_save' then d:=replace(d,quote_literal('week7_'),quote_literal('lab_'));end if;
 if dst='public.studio_lab_command' then d:=replace(d,'''context'',private.lab_context()', '''globalModel'',(select m.identifier from private.week7_models m join private.lab_generation_settings g on g.model_id=m.id where g.id=1),''context'',private.lab_context()');end if;
 -- Studio data has its own transaction lock.
 d:=replace(d,'729100','830200');
 execute d;
 sig:=substring(src from '\(.*$');sig:=replace(sig,'private.week7_steps','private.lab_steps');
 execute 'revoke all on function '||dst||sig||' from public,anon,authenticated';
 end loop;
end$$;
grant execute on function public.studio_lab_command(text,jsonb) to authenticated;
create trigger lab_reset_rule_sections before update of template on private.lab_app_rules for each row execute function private.studio_reset_rule_sections();
notify pgrst,'reload schema';
commit;
