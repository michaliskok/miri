// Does growing a std::vector call the move constructor of a type like genmc::ilist,
// or does it memcpy the elements (which breaks the list)?
#include <cstdio>
#include <vector>

struct node {
	node *next_{};
	node *prev_{};
};

// Same special members as genmc::ilist; DTOR is the only difference between the two lists.
#define LIST(Name, DTOR)                                                                           \
	struct Name {                                                                              \
		Name() { s.next_ = s.prev_ = &s; }                                                 \
		Name(const Name &) = delete;                                                       \
		Name(Name &&o) noexcept : Name()                                                   \
		{                                                                                  \
			if (o.s.prev_ == &o.s)                                                     \
				return;                                                            \
			s.next_ = o.s.next_;                                                       \
			s.prev_ = o.s.prev_;                                                       \
			s.next_->prev_ = &s;                                                       \
			s.prev_->next_ = &s;                                                       \
			o.s.next_ = o.s.prev_ = &o.s;                                              \
		}                                                                                  \
		auto operator=(const Name &) -> Name & = delete;                                   \
		DTOR                                                                               \
		void push_back(node &n)                                                            \
		{                                                                                  \
			n.prev_ = s.prev_;                                                         \
			n.next_ = &s;                                                              \
			s.prev_->next_ = &n;                                                       \
			s.prev_ = &n;                                                              \
		}                                                                                  \
		node s;                                                                            \
	};
LIST(DefaultDtorList, ~DefaultDtorList() = default;)
LIST(UserDtorList, ~UserDtorList() {})

template <typename L> auto check(const char *name) -> bool
{
	std::vector<L> v;
	v.reserve(1);
	v.emplace_back();
	node n;
	v[0].push_back(n);
	v.emplace_back(); // reallocates, relocating v[0]
	bool intact = n.prev_ == &v[0].s && n.next_ == &v[0].s;
#if __has_builtin(__is_trivially_relocatable)
	int builtin = __is_trivially_relocatable(L);
#else
	int builtin = -1;
#endif
	std::printf("%-20s __is_trivially_relocatable=%d  vector growth %s\n", name, builtin,
		    intact ? "kept the list intact" : "BROKE the list (memcpy instead of move)");
	return intact;
}

int main()
{
#ifdef _LIBCPP_VERSION
	std::printf("libc++ %d\n", _LIBCPP_VERSION);
#endif
	bool ok = check<DefaultDtorList>("~ilist() = default;");
	ok &= check<UserDtorList>("~ilist() {}");
	return ok ? 0 : 1;
}
