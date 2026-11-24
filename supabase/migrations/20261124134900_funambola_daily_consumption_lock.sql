create function funambola_private.validate_daily_bonus_use()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare p public.bonus_packs%rowtype;
begin
  select * into strict p from public.bonus_packs where id=new.pack_id for update;
  if p.user_id<>new.user_id or p.cancelled_at is not null
     or p.purchased_at>clock_timestamp() or p.expires_at<=clock_timestamp() then
    raise exception 'El Funámbono no está disponible';
  end if;
  if coalesce(p.adjusted_sessions,p.total_sessions) <=
    (select count(*) from public.bonus_daily_uses where pack_id=p.id) +
    (select count(*) from public.bonus_uses where pack_id=p.id) then
    raise exception 'El Funámbono está agotado';
  end if;
  return new;
end
$fn$;
revoke all on function funambola_private.validate_daily_bonus_use() from public, anon, authenticated;
create trigger validate_daily_bonus_use before insert on public.bonus_daily_uses
  for each row execute function funambola_private.validate_daily_bonus_use();
